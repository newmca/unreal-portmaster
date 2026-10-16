# BCDecode.h: BC1/BC2/BC3 decoding for the Mali renderer

Mali-G31 has no S3TC. The port's renderer, NOpenGLESDrv, sets `SupportsTC=1`,
receives BC1/BC2/BC3 mips untouched and decodes them at upload with
`BCDecode.h`. It starts from a mip no larger than
`MaxDecompressedTextureSize`. The header is C++11, header-only and free of
engine types. Rounding, block layout and BC1 alpha are documented at the top of
the file. It has no build of its own: `NOpenGLESDrv/build.sh` compiles it into
the renderer. Its recorded sha256 is in `NOpenGLESDrv/BUILD.md` and
`SOURCE.md`.

## API

| Function | Purpose |
|---|---|
| `Decode(Format, Src, SrcBytes, W, H, Dst, DstPitch=0)` | Decodes a whole mip to RGBA8 (bytes R,G,B,A). Handles sizes that are not multiples of 4. Returns false and writes nothing on bad input. |
| `DecodeBlockBC1/BC2/BC3(Block, Out, OutPitch)`, `DecodeBlock` | Decodes a single 4x4 block. |
| `CompressedBytes`, `BlockBytes`, `BlockCount`, `RGBA8Bytes`, `HalfSize` | Size helpers. `HalfSize` is max(1, n/2). |
| `DownsampleRGBA8(Src, W, H, Dst)` | 2x2 box filter to `HalfSize(W) x HalfSize(H)`. It may run in place. |
| `SelectBaseMip(Widths, Heights, NumMips, MaxSize)` | Returns the first mip that fits within the cap. If none fits, returns the smallest mip plus `ExtraHalvings`. Pass a size of 0 for mips without data. |

The engine `ETextureFormat` maps as `TEXF_BC1` to `FORMAT_BC1`, `TEXF_BC2` to
`FORMAT_BC2` and `TEXF_BC3` to `FORMAT_BC3`.
