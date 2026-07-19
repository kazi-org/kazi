defmodule KaziWeb.Layouts do
  @moduledoc """
  Root layout for the operator dashboard (T3.6a), carrying the approved
  Mission Control visual design tokens (ADR-0070, `docs/dashboard-design.md`).

  Kept inline and build-free on purpose: the skeleton has no esbuild/tailwind
  bundle. The LiveView client that upgrades the page to a live socket loads
  from the hex packages' own pre-built bundles (`KaziWeb.Endpoint`'s
  `Plug.Static` mounts) — live DOM patching (the poll-tick fleet refresh, the
  drill-in scrubber) needs it. The server-rendered HTML still stands alone for
  the smoke test: with JS unavailable the pages render read-only, as before.

  The `:root` custom properties and the shared, reduced-motion-gated keyframes
  live here (not per-LiveView) so every page -- Mission Control, drill-in,
  transcript peek -- draws from the SAME token set and motion budget. The token
  NAMES are stable across the ADR-0057→0058 revision (`--rail` now tracks
  `--panel`) so the secondary views recolor from the new palette untouched.
  """
  use KaziWeb, :html

  @doc "The outer HTML document wrapping every page."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>kazi · operator dashboard</title>
        <style>
          :root {
            --bg:     #0A0E14;
            --panel:  #0E1520;
            --panel2: #101826;
            --rail:   #0E1520; /* alias of --panel: legacy token name the other pages still use */
            --line:   #1B2634;
            --txt:    #C9D6E4;
            --dim:    #5D7189;
            --cyn:    #53D6FF;
            --grn:    #3DFFA0;
            --red:    #FF5566;
            --amb:    #FFB454;
          }

          body {
            background: var(--bg);
            color: var(--txt);
            font-family: "JetBrains Mono", ui-monospace, monospace;
            font-size: 12px;
          }

          .display-heading {
            font-family: "Space Grotesk", ui-sans-serif, sans-serif;
            font-weight: 700;
          }

          .section-label {
            font-size: 9px;
            letter-spacing: .27em;
            color: var(--dim);
            text-transform: uppercase;
          }

          @media (prefers-reduced-motion: no-preference) {
            /* Mission Control motion budget (ADR-0070): a pulsing LIVE dot, a
               red alarm glow on stuck cards, and the event-river ticker scroll.
               Applied per-view; defined here so the whole surface shares one
               reduced-motion gate. */
            @keyframes mc-pulse {
              0%, 100% { opacity: 1; }
              50% { opacity: .35; }
            }
            @keyframes mc-alarm {
              0%, 100% { box-shadow: 0 0 26px -12px rgba(255,85,102,.7); }
              50% { box-shadow: 0 0 30px -8px rgba(255,85,102,.95); }
            }
            @keyframes mc-scroll {
              from { transform: translateX(0); }
              to { transform: translateX(-50%); }
            }
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          (function () {
            var csrf = document
              .querySelector("meta[name='csrf-token']")
              .getAttribute("content");
            // McDebug (ADR-0078, T63.7): persist the Mission Control operator/
            // debug mode per browser. The URL param `?debug=1` is canonical; this
            // hook mirrors the active mode to localStorage and, on a bare `/`
            // visit, restores a stored debug preference by asking the server to
            // patch the param back in.
            var Hooks = {
              McDebug: {
                mounted: function () {
                  var self = this;
                  this.handleEvent("mc-store-debug", function (payload) {
                    try {
                      window.localStorage.setItem(
                        "kazi:mc-debug",
                        payload.on ? "1" : "0"
                      );
                    } catch (e) {}
                  });
                  try {
                    var url = new URL(window.location.href);
                    if (
                      !url.searchParams.has("debug") &&
                      window.localStorage.getItem("kazi:mc-debug") === "1"
                    ) {
                      self.pushEvent("mc-restore-debug", {});
                    }
                  } catch (e) {}
                },
              },
            };
            var liveSocket = new window.LiveView.LiveSocket(
              "/live",
              window.Phoenix.Socket,
              { params: { _csrf_token: csrf }, hooks: Hooks }
            );
            liveSocket.connect();
            window.liveSocket = liveSocket;
          })();
        </script>
      </body>
    </html>
    """
  end
end
