-- Asked by PortMaster's patcher before install/install.bash runs. The patcher
-- passes the answer to the script as EPIC_TOS=<value>. The wording follows
-- the Terms of Service step of OldUnreal's installers.
return {
  {
    id = "EPIC_TOS",
    question = "Unreal Gold is downloaded from OldUnreal with Epic's approval. The Epic Games Terms of Service apply to it: legal.epicgames.com/en-US/epicgames/tos. Do you agree to them?",
    options = {
      { "agree", "I agree" },
      { "decline", "I do not agree" },
    },
  },
}
