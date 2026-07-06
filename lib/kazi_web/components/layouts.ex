defmodule KaziWeb.Layouts do
  @moduledoc """
  Root layout for the operator dashboard (T3.6a), carrying the approved
  starmap visual design tokens (ADR-0057, `docs/dashboard-design.md`).

  Kept inline and asset-free on purpose: the skeleton has no esbuild/tailwind
  bundle, so the document references no external CSS/JS. The LiveView JS that
  would upgrade the page to a live socket is added when a live surface needs it
  (T3.6b onward); the server-rendered HTML stands alone for the smoke test.

  The `:root` custom properties and the shared, reduced-motion-gated keyframes
  live here (not per-LiveView) so every page --  starmap, drill-in, transcript
  peek -- draws from the SAME token set and motion budget.
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
        <title>kazi · operator dashboard</title>
        <style>
          :root {
            --bg:   #070B16;
            --rail: #0A1120;
            --line: #16233A;
            --txt:  #BFD2EA;
            --dim:  #46587A;
            --cyn:  #56CCF2;
            --grn:  #2EE6A8;
            --red:  #FF5C6C;
            --amb:  #FFB454;
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
            @keyframes starmap-sweep {
              from { transform: rotate(0deg); }
              to { transform: rotate(360deg); }
            }
            @keyframes starmap-ring-pulse {
              from { transform: scale(1); opacity: .9; }
              to { transform: scale(1.7); opacity: 0; }
            }
            @keyframes starmap-livedot-pulse {
              0%, 100% { opacity: 1; }
              50% { opacity: .35; }
            }
            @keyframes starmap-ticker-scroll {
              from { transform: translateX(0); }
              to { transform: translateX(-50%); }
            }
            @keyframes starmap-selring-spin {
              from { transform: rotate(0deg); }
              to { transform: rotate(360deg); }
            }

            .sweep { animation: starmap-sweep 18s linear infinite; }
            .ring { animation: starmap-ring-pulse 2.6s ease-out infinite; }
            .ring.redr { animation-duration: 1.4s; }
            .live-dot { animation: starmap-livedot-pulse 1.6s ease-in-out infinite; }
            .ticker-track { animation: starmap-ticker-scroll 52s linear infinite; }
            .selring { animation: starmap-selring-spin 9s linear infinite; }
          }
        </style>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
