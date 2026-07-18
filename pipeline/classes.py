"""Single source of truth for class/build configuration.

Consolidates what was previously hardcoded independently in at least five
places in the PowerShell pipeline:
  - render_healer_report.ps1's $classSpecByClass class gate
  - update_hub_pages.ps1's separate, independently-duplicated $classSpecMap
    (already bitten twice by drifting out of sync with the other gate - see
    CLAUDE.md's "Explicitly open" item 2g)
  - build_boss_report_data.ps1's $cooldownGuidsByClass
  - each pull_top100_*.ps1's own $className/$classID/$specID header block
  - ReportRenderLib.psm1's $CooldownTargetMode

Every value below was read directly from those real PowerShell sources, not
re-derived from memory - see the migration plan's Phase 1 verification note.
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ClassConfig:
    key: str                        # pipeline-internal -ClassName value: "Druid", "Shaman", "Priest", "Paladin", "Dreamstate"
    wcl_class_name: str               # real WCL className (Dreamstate -> "Druid", NOT "Dreamstate")
    wcl_spec_name: str                 # real WCL specName
    class_id: int                       # real WCL classID
    spec_id: int                         # real WCL specID
    display_name: str                     # "Restoration Druid", "Dreamstate Druid", etc.
    template_name: str                     # boss_page_{x}.html.jinja, under templates_jinja/
    manifest_root_key: str                  # data/Classes/{key}
    cooldown_guids: dict[str, list[int]]      # ability name -> real guid(s), ordered
    target_mode: dict[str, str]                # ability name -> "party"|"self"|"other"
    has_tranquility: bool                        # Druid only
    has_rebirth: bool                             # Druid + Dreamstate
    active_stat_blocks: list[str] = field(default_factory=list)
    mana_potion_name: str = "Restore Mana"


CLASSES: dict[str, ClassConfig] = {
    "Druid": ClassConfig(
        key="Druid",
        wcl_class_name="Druid",
        wcl_spec_name="Restoration",
        class_id=2,
        spec_id=4,
        display_name="Restoration Druid",
        template_name="boss_page_druid.html.jinja",
        manifest_root_key="Druid",
        cooldown_guids={
            "Innervate": [29166],
            "Nature's Swiftness": [17116],
            "Swiftmend": [18562],
            "Tranquility": [26983],
            "Rebirth": [26994],
            "Dark Rune": [27869],
        },
        target_mode={
            "Innervate": "other", "Nature's Swiftness": "self", "Swiftmend": "other",
            "Tranquility": "other", "Rebirth": "other", "Dark Rune": "self", "Mana Potion": "self",
        },
        has_tranquility=True,
        has_rebirth=True,
        active_stat_blocks=["Flask", "Food", "TreeOfLife", "ManaConsumable", "HPM"],
    ),
    "Shaman": ClassConfig(
        key="Shaman",
        wcl_class_name="Shaman",
        wcl_spec_name="Restoration",
        class_id=9,
        spec_id=3,
        display_name="Restoration Shaman",
        template_name="boss_page_shaman.html.jinja",
        manifest_root_key="Shaman",
        cooldown_guids={
            "Earth Shield": [32594],
            "Mana Tide Totem": [16190],
            "Ancestral Swiftness": [16188],
            "Dark Rune": [27869],
        },
        target_mode={
            "Earth Shield": "other", "Mana Tide Totem": "party", "Ancestral Swiftness": "party",
            "Dark Rune": "self", "Mana Potion": "self",
        },
        has_tranquility=False,
        has_rebirth=False,
        active_stat_blocks=["Flask", "Food", "ManaConsumable", "HPM"],
    ),
    "Priest": ClassConfig(
        key="Priest",
        wcl_class_name="Priest",
        wcl_spec_name="Holy",
        class_id=7,
        spec_id=2,
        display_name="Holy Priest",
        template_name="boss_page_priest.html.jinja",
        manifest_root_key="Priest",
        cooldown_guids={
            "Shadowfiend": [34433],
            "Power Word: Shield": [10899],
            "Chakra": [14751],
            "Blessing of Life": [38332],
            "Fear Ward": [6346],
            "Dark Rune": [27869],
        },
        target_mode={
            "Shadowfiend": "self", "Power Word: Shield": "other", "Chakra": "self",
            "Blessing of Life": "self", "Fear Ward": "other", "Dark Rune": "self", "Mana Potion": "self",
        },
        has_tranquility=False,
        has_rebirth=False,
        active_stat_blocks=["Flask", "Food", "ManaConsumable", "HPM"],
    ),
    "Paladin": ClassConfig(
        key="Paladin",
        wcl_class_name="Paladin",
        wcl_spec_name="Holy",
        class_id=6,
        spec_id=1,
        display_name="Holy Paladin",
        template_name="boss_page_paladin.html.jinja",
        manifest_root_key="Paladin",
        cooldown_guids={
            "Holy Shock": [33072],
            "Divine Favor": [20216],
            "Divine Shield": [1020],
            "Cleanse": [4987],
            "Hand of Protection": [10278],
            "Blessing of Freedom": [1044],
            "Dark Rune": [27869],
        },
        target_mode={
            "Holy Shock": "other", "Divine Favor": "self", "Divine Shield": "self",
            "Cleanse": "other", "Hand of Protection": "other", "Blessing of Freedom": "other",
            "Dark Rune": "self", "Mana Potion": "self",
        },
        has_tranquility=False,
        has_rebirth=False,
        active_stat_blocks=["Flask", "Food", "ManaConsumable", "HPM"],
    ),
    # Dreamstate is a SPEC of Druid, not a separate real WCL class - real
    # wcl_class_name is "Druid", real wcl_spec_name is "Dreamstate". Kept as a
    # distinct pipeline-key entry (own manifest_root_key) on purpose - see
    # CLAUDE.md's "Mid-raid spec switching" section for the real case
    # (Turkeykin) that required this class/pipeline-key split.
    "Dreamstate": ClassConfig(
        key="Dreamstate",
        wcl_class_name="Druid",
        wcl_spec_name="Dreamstate",
        class_id=2,
        spec_id=6,
        display_name="Dreamstate Druid",
        template_name="boss_page_dreamstate.html.jinja",
        manifest_root_key="Dreamstate",
        cooldown_guids={
            "Innervate": [29166],
            "Rebirth": [26994],
            "Dark Rune": [27869],
        },
        target_mode={
            "Innervate": "other", "Rebirth": "other", "Dark Rune": "self", "Mana Potion": "self",
        },
        has_tranquility=False,
        has_rebirth=True,
        active_stat_blocks=["Flask", "Food", "ImprovedFaerieFire", "ManaConsumable", "HPM"],
    ),
}


def get(class_name: str) -> ClassConfig:
    """Raises KeyError with the same hard-stop intent as the PS scripts'
    'no real cooldown-guid table for this class yet' checks - never silently
    fall back to a default/empty config for an unknown class."""
    if class_name not in CLASSES:
        raise KeyError(
            f"'{class_name}' has no real class config yet - only "
            f"{', '.join(CLASSES.keys())} are wired up today. Add a real, "
            f"VERIFIED entry (never guess at guids) before running this for "
            f"that class."
        )
    return CLASSES[class_name]
