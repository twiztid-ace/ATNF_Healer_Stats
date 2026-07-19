"""Per-character visual theme overrides for the generated site.

Every boss-page/raid-overview/hub template gets its whole color palette from
one :root{} block of CSS custom properties (--ink, --parchment, --copper,
--moss, --rust, --gold, --line - see any templates_jinja/*.jinja file's
<style> block). CHARACTER_THEMES lets one specific character override a
subset of those variables, plus add a small header flourish, WITHOUT forking
their shared per-build template: render_report.py and hub_pages.py inject the
override as a second :root{} block placed right after the template's own
default one, so the CSS cascade lets it win, and every other healer sharing
that same template is untouched. Character name -> theme, not class/build ->
theme; a healer with no entry here renders with the template's own defaults
exactly as before this module existed.
"""

from __future__ import annotations

CHARACTER_THEMES: dict[str, dict] = {
    # Tauren Druid palette: sun-baked Mulgore hide/clay instead of the site
    # default's cool ink/teal parchment scheme - reuses the same variable
    # names so every existing var(--copper) etc. reference just picks up the
    # new color with no template body changes.
    "Danceswtrees": {
        "vars": {
            "--ink": "#2B1B12",
            "--ink-2": "#3E2A1A",
            "--parchment": "#EDE0C4",
            "--parchment-dim": "#E1CFA4",
            "--copper": "#B5451F",
            "--moss": "#4F6B34",
            "--rust": "#7A2E1F",
            "--gold": "#C79A2E",
            "--line": "rgba(43,27,18,0.20)",
        },
        "tag": "Bloodhoof Clan · Mulgore",
        # Path is relative to docs/{healer_slug}/ (that character's own docs
        # root) - callers supply a path_prefix ("" from the hub page itself,
        # "../" from a report-code subfolder one level deeper) to resolve it
        # to the right relative URL for wherever the page actually lives.
        "bg_image": "assets/bg-tauren-druid.jpg",
    },
}


def theme_style_block(character_name: str, path_prefix: str = "", bg_fill_viewport: bool = False) -> str:
    """A second <style> block: a :root{} override for this character's vars,
    plus (if set) a body{} background-image rule pointing at their bg_image -
    or "" for a character with no theme (the template renders unchanged).

    bg_fill_viewport=True (raid-overview/boss pages) pins the image to the
    browser window itself - background-size/position become percentages of
    the viewport rather than the (possibly taller, scrollable) document once
    background-attachment is fixed, so the whole image is always visible,
    unstretched by document height, and doesn't move as the page scrolls.
    bg_fill_viewport=False (the hub/raid-list page) keeps the plain "cover"
    behavior from before this option existed."""
    theme = CHARACTER_THEMES.get(character_name)
    if not theme:
        return ""
    rules = "\n".join(f"    {k}: {v};" for k, v in theme["vars"].items())
    block = f"<style>\n  :root{{\n{rules}\n  }}"
    bg_image = theme.get("bg_image")
    if bg_image:
        url = f"{path_prefix}{bg_image}"
        if bg_fill_viewport:
            bg_rules = (
                f"    background-image: url('{url}');\n"
                "    background-size: 100% 100%;\n"
                "    background-position: center center;\n"
                "    background-repeat: no-repeat;\n"
                "    background-attachment: fixed;\n"
            )
        else:
            bg_rules = (
                f"    background-image: url('{url}');\n"
                "    background-size: cover;\n"
                "    background-position: center center;\n"
                "    background-repeat: no-repeat;\n"
            )
        block += "\n  body{\n" + bg_rules + "  }"
    block += "\n</style>"
    return block


def theme_tag(character_name: str) -> str | None:
    """A short header flourish string, or None for a character with no theme."""
    theme = CHARACTER_THEMES.get(character_name)
    return theme.get("tag") if theme else None
