# hub :dev profile config layer (void/core/config: plugin
# defaults <- config files <- VOID_* env vars <- CLI overrides).
{:http {:port 8080}

 # letters land in a directory instead of a network: `:file` is a real
 # transport with a real delivery, which is what lets the reset link be
 # opened on a laptop that has no mail server anywhere near it
 :mail {:transport :file :base-url "http://localhost:8080"}

 # On a laptop everything that arrives goes to the one chat, and the
 # rule names the channel rather than the chat: which chat is
 # `[:hub :telegram :chat-id]`, and that — like the bot token and the
 # webhook secret — comes from the environment, because none of the
 # three belongs in a file this repository keeps:
 #
 #     VOID_HUB__SOURCES__GITHUB__SIGNING_SECRET=...
 #     VOID_HUB__TELEGRAM__TOKEN=...
 #     VOID_HUB__TELEGRAM__CHAT_ID=...
 :hub {:rules [{:when {:source "github"} :to [:telegram]}]}}
