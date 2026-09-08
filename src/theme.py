"""
Enhancify Theme Engine & Registry
Provides multiple handcrafted color themes with live preview palettes and instant switching.
"""

from dataclasses import dataclass
from typing import Dict, List, Optional

from src.config import config


@dataclass
class ThemeInfo:
    id: str
    name: str
    description: str
    primary_color: str
    secondary_color: str
    bg_color: str
    css_class: str
    badge_style: str
    preview_palette: List[str]


THEMES: List[ThemeInfo] = [
    ThemeInfo(
        id="cyber_green",
        name="Cybernetic Green",
        description="Classic Enhancify emerald green with high-contrast cyber aesthetic",
        primary_color="#00ff7f",
        secondary_color="#00e5ff",
        bg_color="#0d1117",
        css_class="theme-cyber-green",
        badge_style="badge-green",
        preview_palette=["#00ff7f", "#00e5ff", "#161b22", "#0d1117"],
    ),
    ThemeInfo(
        id="cyberpunk_neon",
        name="Cyberpunk Neon",
        description="High-energy electric neon pink, hot magenta, and cyan glow",
        primary_color="#ff007f",
        secondary_color="#00f0ff",
        bg_color="#0c0817",
        css_class="theme-cyberpunk-neon",
        badge_style="badge-pink",
        preview_palette=["#ff007f", "#00f0ff", "#171126", "#0c0817"],
    ),
    ThemeInfo(
        id="dracula",
        name="Dracula Vampire",
        description="Classic dark theme with vibrant pastel purple, pink, and green accents",
        primary_color="#bd93f9",
        secondary_color="#ff79c6",
        bg_color="#1e1f29",
        css_class="theme-dracula",
        badge_style="badge-purple",
        preview_palette=["#bd93f9", "#ff79c6", "#50fa7b", "#282a36"],
    ),
    ThemeInfo(
        id="catppuccin",
        name="Catppuccin Mocha",
        description="Soothing pastel palette with mauve, sky blue, and sapphire tones",
        primary_color="#cba6f7",
        secondary_color="#89dceb",
        bg_color="#181825",
        css_class="theme-catppuccin",
        badge_style="badge-mauve",
        preview_palette=["#cba6f7", "#89dceb", "#a6e3a1", "#1e1e2e"],
    ),
    ThemeInfo(
        id="nordic_frost",
        name="Nordic Frost",
        description="Arctic-inspired cool frost blues, aurora cyan, and polar night slate",
        primary_color="#88c0d0",
        secondary_color="#81a1c1",
        bg_color="#242933",
        css_class="theme-nordic-frost",
        badge_style="badge-nord",
        preview_palette=["#88c0d0", "#81a1c1", "#a3be8c", "#2e3440"],
    ),
    ThemeInfo(
        id="sunset_amber",
        name="Sunset Amber",
        description="Warm golden amber, blazing sunset orange, and rich dark charcoal",
        primary_color="#ffb703",
        secondary_color="#fb8500",
        bg_color="#14110e",
        css_class="theme-sunset-amber",
        badge_style="badge-yellow",
        preview_palette=["#ffb703", "#fb8500", "#06d6a0", "#1f1a15"],
    ),
    ThemeInfo(
        id="matrix_retro",
        name="Matrix Phosphor",
        description="Pure retro terminal black and lime-green CRT phosphor glow",
        primary_color="#00ff00",
        secondary_color="#39ff14",
        bg_color="#000000",
        css_class="theme-matrix-retro",
        badge_style="badge-matrix",
        preview_palette=["#00ff00", "#39ff14", "#041004", "#000000"],
    ),
    ThemeInfo(
        id="oled_midnight",
        name="OLED Midnight Dark",
        description="Deep pitch black with ice blue accents, tuned for battery savings on AMOLED",
        primary_color="#00a8ff",
        secondary_color="#ffffff",
        bg_color="#000000",
        css_class="theme-oled-midnight",
        badge_style="badge-cyan",
        preview_palette=["#00a8ff", "#ffffff", "#111111", "#000000"],
    ),
]


THEME_MAP: Dict[str, ThemeInfo] = {t.id: t for t in THEMES}


def get_current_theme() -> ThemeInfo:
    """Read active theme from configuration."""
    theme_id = config.get("THEME_ID", "")
    if theme_id and theme_id in THEME_MAP:
        return THEME_MAP[theme_id]

    # Fallback to GREEN_THEME legacy toggle
    if config.is_on("GREEN_THEME"):
        return THEME_MAP["cyber_green"]
    elif config.is_on("DARK_THEME"):
        return THEME_MAP["oled_midnight"]
    return THEME_MAP["cyber_green"]


def set_current_theme(theme_id: str) -> bool:
    """Save active theme to config."""
    if theme_id not in THEME_MAP:
        return False

    theme = THEME_MAP[theme_id]
    config.set("THEME_ID", theme.id)
    config.set("THEME", theme.name)

    # Maintain legacy toggles
    if theme.id == "cyber_green":
        config.set("GREEN_THEME", "on")
        config.set("DARK_THEME", "off")
    else:
        config.set("GREEN_THEME", "off")
        config.set("DARK_THEME", "on")

    return True
