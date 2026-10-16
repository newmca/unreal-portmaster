/*=============================================================================
	BCDecode.h: BC1/BC2/BC3 (DXT1/DXT3/DXT5) to RGBA8 decoder, RGBA8 2x2 box
	downsampler and mip cap selection.

	Mali-G31 (libmali r20p0) has no S3TC, so the Unreal Gold 227 renderers of
	this port (OpenGLDrv and NOpenGLESDrv) set SupportsTC=1, receive BC1/2/3
	mips untouched and decode them here at upload time, starting from a mip
	no larger than MaxDecompressedTextureSize.

	Header-only, C++11, no engine types and nothing beyond the C standard
	library, so both renderers can include it and wrap it around their
	FTextureInfo handling.

	Output is RGBA8 with byte order R,G,B,A in memory (GL_RGBA with
	GL_UNSIGNED_BYTE, TEXF_RGBA8_).

	References:
	 [DFS] Khronos Data Format Specification 1.3, chapter 18 "S3TC Compressed
	       Texture Image Formats" (18.1-18.4).
	 [D3D] Direct3D 10 "Block Compression" (BC1/BC2/BC3).
	 [227] OldUnreal 227k_15 SDK Engine/Inc/UnTexComp.h (FDecompressBlockBC*)
	       and Engine/Inc/UnColor.h (FRed5Green6Blue5::Expand*RGBA8).

	Block layout (all multi-byte fields little-endian) [DFS]:
	 * The image is a row-major raster of 4x4 blocks, ceil(W/4)*ceil(H/4)
	   of them, so 1x1 and 2x2 mips still occupy one whole block. Texels of
	   edge blocks that fall outside the mip are ignored.
	 * Colour block, 8 bytes: color0 (RGB565), color1 (RGB565), then
	   32 bits of 2-bit indices, texel (x,y) at bit 2*(4*y+x).
	 * BC1 = colour block. BC2 = 64 bits of 4-bit alpha (texel (x,y) at bit
	   4*(4*y+x)) + colour block. BC3 = alpha0, alpha1, 48 bits of 3-bit
	   indices (texel (x,y) at bit 3*(4*y+x)) + colour block.

	Palettes [DFS]:
	 * color0 > color1 (16-bit compare), and always for BC2/BC3:
	   c0, c1, (2*c0+c1)/3, (c0+2*c1)/3.
	 * color0 <= color1, BC1 only: c0, c1, (c0+c1)/2, transparent black.
	   This is "BC1 with alpha" (DXT1 RGBA, GL_COMPRESSED_RGBA_S3TC_DXT1_EXT).
	   227's FDecompressBlockBC1 returns opaque black here, which removes
	   the cut-outs of DXT1 HD textures; FDecompressBlockBC1_PA matches this
	   decoder.
	 * BC2 alpha: a/15.
	 * BC3 alpha, alpha0 > alpha1: a0, a1, ((7-i)*a0+i*a1)/7 for i=1..6.
	   alpha0 <= alpha1: a0, a1, ((5-i)*a0+i*a1)/5 for i=1..4, 0, 255.

	Rounding:
	 The specs define endpoints as c/31, c/63, a/255 and the interpolated
	 entries as the exact rational values above; they do not prescribe a
	 rounding to 8 bits. This decoder returns the exact value rounded to the
	 nearest integer, computed in integer math straight from the 5/6/8-bit
	 endpoints:

	                      5-bit (R,B)               6-bit (G)
	   endpoint           (c*255+15)/31             (c*255+31)/63
	   (2*c0+c1)/3        ((2*c0+c1)*255+46)/93     ((2*c0+c1)*255+94)/189
	   (c0+c1)/2          ((c0+c1)*255+31)/62       ((c0+c1)*255+63)/126
	   BC3 7-step alpha   ((7-i)*a0+i*a1+3)/7
	   BC3 5-step alpha   ((5-i)*a0+i*a1+2)/5
	   BC2 alpha          a*17 (exact)

	 Only (c0+c1)/2 can land exactly on .5 (e.g. 127.5); it rounds up.
	 Reasons for this choice:
	  1. It is the error-free result of the spec formulas, with no darkening
	     bias (truncating decoders lose up to 1 on interpolated entries).
	  2. It is bit-identical to 227's own BC1_PA/BC2/BC3 decoders [227], so a
	     mip decodes to the same texels whether the engine decompresses it
	     (SupportsTC=0, any stock renderer) or our renderer does, BC1
	     punch-through texels excepted (see Palettes).
	 Decoders that expand endpoints by bit replication and truncate the
	 interpolation (Pillow, texture2ddecoder) differ from this one by at most
	 1 per channel (exhaustive over all endpoints, see ComputeTolerance in
	 tests/BCDecodeTest.cpp).

	Downsampling:
	 DownsampleRGBA8 is a plain per-channel box average, alpha included, of
	 straight (not premultiplied) RGBA, rounded to nearest. Next to the
	 transparent black texels of BC1 cut-outs this darkens colour and gives
	 fractional alpha at the edge, as any non-premultiplied mip filter does.
=============================================================================*/

#ifndef BCDECODE_H
#define BCDECODE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace BCDecode
{

/*-----------------------------------------------------------------------------
	Formats and sizes.
-----------------------------------------------------------------------------*/

enum EFormat
{
	FORMAT_BC1, // DXT1: 8 bytes per 4x4 block, RGB with 1-bit punch-through alpha.
	FORMAT_BC2, // DXT3: 16 bytes per block, explicit 4-bit alpha + BC1 colour.
	FORMAT_BC3, // DXT5: 16 bytes per block, interpolated 8-bit alpha + BC1 colour.
};

// Bytes per 4x4 block.
inline size_t BlockBytes( EFormat Format )
{
	return Format==FORMAT_BC1 ? 8 : 16;
}

// Number of blocks covering Size texels (a 1 or 2 texel edge still needs a whole block).
inline size_t BlockCount( uint32_t Size )
{
	return ((size_t)Size+3)/4;
}

// Bytes of compressed data a Width x Height mip occupies.
inline size_t CompressedBytes( EFormat Format, uint32_t Width, uint32_t Height )
{
	return BlockCount(Width)*BlockCount(Height)*BlockBytes(Format);
}

// Bytes of a tightly packed Width x Height RGBA8 image.
inline size_t RGBA8Bytes( uint32_t Width, uint32_t Height )
{
	return (size_t)Width*Height*4;
}

// Size of the next mip level: halved, rounded down, never below 1 (GL/D3D rule).
inline uint32_t HalfSize( uint32_t Size )
{
	return Size>1 ? Size/2 : 1;
}

/*-----------------------------------------------------------------------------
	Implementation details.
-----------------------------------------------------------------------------*/

namespace Detail
{
	inline uint32_t Load16( const uint8_t* P )
	{
		return (uint32_t)P[0] | ((uint32_t)P[1]<<8);
	}
	inline uint32_t Load32( const uint8_t* P )
	{
		return (uint32_t)P[0] | ((uint32_t)P[1]<<8) | ((uint32_t)P[2]<<16) | ((uint32_t)P[3]<<24);
	}
	inline uint64_t Load48( const uint8_t* P )
	{
		return (uint64_t)Load32(P) | ((uint64_t)Load16(P+4)<<32);
	}

	// Correctly rounded endpoint expansion and interpolation, see "Rounding" above.
	// Sum3 is 2*c0+c1 or c0+2*c1, Sum2 is c0+c1.
	inline uint8_t Expand5( uint32_t C )   { return (uint8_t)((C*255+15)/31); }
	inline uint8_t Expand6( uint32_t C )   { return (uint8_t)((C*255+31)/63); }
	inline uint8_t Third5( uint32_t Sum3 ) { return (uint8_t)((Sum3*255+46)/93); }
	inline uint8_t Third6( uint32_t Sum3 ) { return (uint8_t)((Sum3*255+94)/189); }
	inline uint8_t Half5( uint32_t Sum2 )  { return (uint8_t)((Sum2*255+31)/62); }
	inline uint8_t Half6( uint32_t Sum2 )  { return (uint8_t)((Sum2*255+63)/126); }

	inline void SetRGBA( uint8_t* Texel, uint8_t R, uint8_t G, uint8_t B, uint8_t A )
	{
		Texel[0] = R;
		Texel[1] = G;
		Texel[2] = B;
		Texel[3] = A;
	}

	//
	// RGBA palette of the 8-byte colour block shared by BC1, BC2 and BC3.
	// Only BC1 (bPunchThrough) switches to three colours plus transparent
	// black when color0 <= color1; BC2/BC3 always use four colours [DFS 18.3/18.4].
	//
	inline void BuildColorPalette( const uint8_t* ColorBlock, bool bPunchThrough, uint8_t Palette[4][4] )
	{
		const uint32_t C0 = Load16(ColorBlock+0);
		const uint32_t C1 = Load16(ColorBlock+2);
		const uint32_t R0 = C0>>11, G0 = (C0>>5)&63, B0 = C0&31;
		const uint32_t R1 = C1>>11, G1 = (C1>>5)&63, B1 = C1&31;

		SetRGBA( Palette[0], Expand5(R0), Expand6(G0), Expand5(B0), 255 );
		SetRGBA( Palette[1], Expand5(R1), Expand6(G1), Expand5(B1), 255 );
		if ( C0>C1 || !bPunchThrough )
		{
			SetRGBA( Palette[2], Third5(2*R0+R1), Third6(2*G0+G1), Third5(2*B0+B1), 255 );
			SetRGBA( Palette[3], Third5(R0+2*R1), Third6(G0+2*G1), Third5(B0+2*B1), 255 );
		}
		else
		{
			SetRGBA( Palette[2], Half5(R0+R1), Half6(G0+G1), Half5(B0+B1), 255 );
			SetRGBA( Palette[3], 0, 0, 0, 0 );
		}
	}

	// Writes the 16 texels of a colour block through Palette, row Y at Out+Y*Pitch.
	inline void WriteColors( const uint8_t* ColorBlock, const uint8_t Palette[4][4], uint8_t* Out, size_t Pitch )
	{
		uint32_t Indices = Load32(ColorBlock+4);
		for ( int Y=0; Y<4; Y++, Out+=Pitch )
			for ( int X=0; X<4; X++, Indices>>=2 )
				memcpy( Out+X*4, Palette[Indices&3], 4 );
	}
}

/*-----------------------------------------------------------------------------
	Block decoders.

	Each decodes one block into 4x4 RGBA8 texels; texel (X,Y) of the block
	is written to Out+Y*OutPitch+X*4.
-----------------------------------------------------------------------------*/

inline void DecodeBlockBC1( const uint8_t* Block, uint8_t* Out, size_t OutPitch )
{
	uint8_t Palette[4][4];
	Detail::BuildColorPalette( Block, true, Palette );
	Detail::WriteColors( Block, Palette, Out, OutPitch );
}

inline void DecodeBlockBC2( const uint8_t* Block, uint8_t* Out, size_t OutPitch )
{
	uint8_t Palette[4][4];
	Detail::BuildColorPalette( Block+8, false, Palette );
	Detail::WriteColors( Block+8, Palette, Out, OutPitch );

	// Explicit alpha: one 16-bit row of four nibbles per texel row, a/15 == a*17/255.
	for ( int Y=0; Y<4; Y++, Out+=OutPitch )
	{
		const uint32_t Row = Detail::Load16( Block+2*Y );
		for ( int X=0; X<4; X++ )
			Out[X*4+3] = (uint8_t)(((Row>>(4*X))&15)*17);
	}
}

inline void DecodeBlockBC3( const uint8_t* Block, uint8_t* Out, size_t OutPitch )
{
	uint8_t Palette[4][4];
	Detail::BuildColorPalette( Block+8, false, Palette );
	Detail::WriteColors( Block+8, Palette, Out, OutPitch );

	// Alpha palette: two endpoints, then six interpolated values (alpha0 > alpha1)
	// or four interpolated values plus 0 and 255 (alpha0 <= alpha1).
	const uint32_t A0 = Block[0];
	const uint32_t A1 = Block[1];
	uint8_t Alpha[8];
	Alpha[0] = (uint8_t)A0;
	Alpha[1] = (uint8_t)A1;
	if ( A0>A1 )
	{
		for ( uint32_t i=1; i<=6; i++ )
			Alpha[1+i] = (uint8_t)(((7-i)*A0 + i*A1 + 3)/7);
	}
	else
	{
		for ( uint32_t i=1; i<=4; i++ )
			Alpha[1+i] = (uint8_t)(((5-i)*A0 + i*A1 + 2)/5);
		Alpha[6] = 0;
		Alpha[7] = 255;
	}

	uint64_t Indices = Detail::Load48( Block+2 );
	for ( int Y=0; Y<4; Y++, Out+=OutPitch )
		for ( int X=0; X<4; X++, Indices>>=3 )
			Out[X*4+3] = Alpha[Indices&7];
}

inline void DecodeBlock( EFormat Format, const uint8_t* Block, uint8_t* Out, size_t OutPitch )
{
	switch ( Format )
	{
		case FORMAT_BC1: DecodeBlockBC1( Block, Out, OutPitch ); break;
		case FORMAT_BC2: DecodeBlockBC2( Block, Out, OutPitch ); break;
		case FORMAT_BC3: DecodeBlockBC3( Block, Out, OutPitch ); break;
	}
}

/*-----------------------------------------------------------------------------
	Image decoder.
-----------------------------------------------------------------------------*/

namespace Detail
{
	// Block loop, instantiated per format so DecodeBlock's switch folds away.
	template<EFormat Format> inline void DecodeBlocks( const uint8_t* Block, uint32_t Width, uint32_t Height, uint8_t* Dst, size_t DstPitch )
	{
		const size_t Step = BlockBytes(Format);
		for ( uint32_t Y=0; Y<Height; Y+=4 )
		{
			for ( uint32_t X=0; X<Width; X+=4, Block+=Step )
			{
				uint8_t* Out = Dst + Y*DstPitch + (size_t)X*4;
				if ( Width-X>=4 && Height-Y>=4 )
				{
					DecodeBlock( Format, Block, Out, DstPitch );
				}
				else
				{
					// Edge block of a mip that is not a multiple of 4 (or smaller
					// than one block): decode to scratch, copy the texels inside the mip.
					uint8_t Texels[4*4*4];
					DecodeBlock( Format, Block, Texels, 4*4 );
					const uint32_t CopyW = Width-X<4 ? Width-X : 4;
					const uint32_t CopyH = Height-Y<4 ? Height-Y : 4;
					for ( uint32_t Row=0; Row<CopyH; Row++ )
						memcpy( Out+Row*DstPitch, Texels+Row*4*4, (size_t)CopyW*4 );
				}
			}
		}
	}
}

//
// Decodes a whole Width x Height mip of Format into RGBA8.
// Src holds SrcBytes of block data (at least CompressedBytes(Format,Width,Height)).
// Row Y of the result starts at Dst+Y*DstPitch; DstPitch 0 means tightly packed (Width*4).
// Writes only the Width*4 bytes of each of the Height rows.
// Returns false, without writing anything, on a zero size, a too short source
// or a pitch smaller than Width*4.
//
inline bool Decode( EFormat Format, const void* Src, size_t SrcBytes, uint32_t Width, uint32_t Height, void* Dst, size_t DstPitch=0 )
{
	if ( DstPitch==0 )
		DstPitch = (size_t)Width*4;
	if ( !Src || !Dst || Width==0 || Height==0 || DstPitch<(size_t)Width*4 || SrcBytes<CompressedBytes(Format,Width,Height) )
		return false;

	const uint8_t* Block = (const uint8_t*)Src;
	uint8_t* Out = (uint8_t*)Dst;
	switch ( Format )
	{
		case FORMAT_BC1: Detail::DecodeBlocks<FORMAT_BC1>( Block, Width, Height, Out, DstPitch ); return true;
		case FORMAT_BC2: Detail::DecodeBlocks<FORMAT_BC2>( Block, Width, Height, Out, DstPitch ); return true;
		case FORMAT_BC3: Detail::DecodeBlocks<FORMAT_BC3>( Block, Width, Height, Out, DstPitch ); return true;
	}
	return false;
}

/*-----------------------------------------------------------------------------
	2x2 box downsampler.
-----------------------------------------------------------------------------*/

//
// Halves a tightly packed Width x Height RGBA8 image into a tightly packed
// HalfSize(Width) x HalfSize(Height) image at Dst. Dst may equal Src (in place).
//
// Each output texel is the rounded average of its 2x2 source texels. A
// dimension of 1 is not halved (1xN averages vertical pairs). With an odd
// dimension the last row/column of the source is folded into the last
// output row/column (a 3 texel footprint), so no source texel is dropped.
// Plain straight-alpha average; see "Downsampling" at the top of the file.
//
inline void DownsampleRGBA8( const void* Src, uint32_t Width, uint32_t Height, void* Dst )
{
	const uint8_t* In  = (const uint8_t*)Src;
	uint8_t*       Out = (uint8_t*)Dst;
	const uint32_t OutW = HalfSize(Width);
	const uint32_t OutH = HalfSize(Height);

	for ( uint32_t Y=0; Y<OutH; Y++ )
	{
		const uint32_t Y0   = Height>1 ? 2*Y : 0;
		const uint32_t NumY = Height==1 ? 1 : (Y==OutH-1 && (Height&1)) ? 3 : 2;
		for ( uint32_t X=0; X<OutW; X++ )
		{
			const uint32_t X0   = Width>1 ? 2*X : 0;
			const uint32_t NumX = Width==1 ? 1 : (X==OutW-1 && (Width&1)) ? 3 : 2;

			// All source texels of this output texel are read before it is
			// written; its index never exceeds theirs, hence in place is safe.
			uint32_t Sum[4] = { 0, 0, 0, 0 };
			for ( uint32_t SY=0; SY<NumY; SY++ )
			{
				const uint8_t* Row = In + ((size_t)(Y0+SY)*Width + X0)*4;
				for ( uint32_t SX=0; SX<NumX*4; SX++ )
					Sum[SX&3] += Row[SX];
			}
			const uint32_t Num = NumX*NumY;
			uint8_t* Texel = Out + ((size_t)Y*OutW + X)*4;
			if ( Num==4 )
			{
				for ( int C=0; C<4; C++ )
					Texel[C] = (uint8_t)((Sum[C]+2)>>2);
			}
			else
			{
				for ( int C=0; C<4; C++ )
					Texel[C] = (uint8_t)((Sum[C]+Num/2)/Num);
			}
		}
	}
}

/*-----------------------------------------------------------------------------
	Mip cap selection.
-----------------------------------------------------------------------------*/

struct MipSelection
{
	int      BaseMip;       // Chain index to decode, or -1 if no mip is usable.
	uint32_t ExtraHalvings; // DownsampleRGBA8 passes to run on the decoded BaseMip.
	uint32_t Width;         // Size after those passes, i.e. the uploaded level 0.
	uint32_t Height;
};

//
// Picks the mip to decode so the uploaded texture is at most MaxSize x MaxSize.
// MipWidths/MipHeights describe the chain (NumMips entries, largest first).
// A mip with a zero dimension counts as unusable; pass 0 for mips without
// data, as OpenGLDrv's GetBaseMip skips them. MaxSize 0 means no cap.
//
// Returns the first usable mip with both dimensions <= MaxSize and
// ExtraHalvings 0. If no usable mip is that small (e.g. a 4096x4096 texture
// stored without mips), returns the smallest usable mip and the number of
// HalfSize steps that bring both of its dimensions within MaxSize.
//
inline MipSelection SelectBaseMip( const uint32_t* MipWidths, const uint32_t* MipHeights, int NumMips, uint32_t MaxSize )
{
	MipSelection Result = { -1, 0, 0, 0 };
	for ( int i=0; i<NumMips; i++ )
	{
		const uint32_t W = MipWidths[i];
		const uint32_t H = MipHeights[i];
		if ( W==0 || H==0 )
			continue;
		if ( MaxSize==0 || (W<=MaxSize && H<=MaxSize) )
		{
			Result.BaseMip = i;
			Result.Width   = W;
			Result.Height  = H;
			return Result;
		}
		const uint32_t Largest     = W>H ? W : H;
		const uint32_t BestLargest = Result.Width>Result.Height ? Result.Width : Result.Height;
		if ( Result.BaseMip<0 || Largest<BestLargest )
		{
			Result.BaseMip = i;
			Result.Width   = W;
			Result.Height  = H;
		}
	}
	while ( Result.BaseMip>=0 && (Result.Width>MaxSize || Result.Height>MaxSize) )
	{
		Result.Width  = HalfSize(Result.Width);
		Result.Height = HalfSize(Result.Height);
		Result.ExtraHalvings++;
	}
	return Result;
}

} // namespace BCDecode

#endif // BCDECODE_H
