import coralFavicon from "../../../assets/favicon-coral.png?inline"
import chonkFavicon from "../../../assets/favicon-chonk.png?inline"
import evaFavicon from "../../../assets/favicon-eva-01.png?inline"

export const planDesignStorageKey = "matcha-plan-design"
export const evaThemeStorageKey = "matcha-eva-theme"

export type PlanDesign = "coral" | "chonk" | "eva-01"
export type EvaTheme = "dark" | "light"

export const defaultPlanDesign: PlanDesign = "coral"
export const defaultEvaTheme: EvaTheme = "dark"

export const planDesigns: readonly PlanDesign[] = ["chonk", "coral", "eva-01"] as const

export function isPlanDesign(value: string | null | undefined): value is PlanDesign {
  return value === "coral" || value === "chonk" || value === "eva-01"
}

export function isEvaTheme(value: string | null | undefined): value is EvaTheme {
  return value === "dark" || value === "light"
}

export function readStoredPlanDesign(storageKey = planDesignStorageKey): PlanDesign {
  const initial = typeof document !== "undefined" ? document.documentElement.dataset.initialDesign : undefined
  if (isPlanDesign(initial)) return initial
  try {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem(storageKey)
      if (isPlanDesign(saved)) {
        return saved
      }
    }
  } catch {}
  return defaultPlanDesign
}

export function writeStoredPlanDesign(design: PlanDesign, storageKey = planDesignStorageKey): void {
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(storageKey, design)
    }
  } catch {}
}

function getEvaThemeStorageKey(): string {
  return (typeof document !== "undefined" && document.documentElement.dataset.evaThemeStorageKey) || evaThemeStorageKey
}

export function readStoredEvaTheme(storageKey = getEvaThemeStorageKey()): EvaTheme {
  const initial = typeof document !== "undefined" ? document.documentElement.dataset.initialEvaTheme : undefined
  try {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem(storageKey)
      if (isEvaTheme(saved)) {
        return saved
      }
    }
  } catch {}
  return isEvaTheme(initial) ? initial : defaultEvaTheme
}

export function writeStoredEvaTheme(theme: EvaTheme, storageKey = getEvaThemeStorageKey()): void {
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(storageKey, theme)
    }
  } catch {}
}

export function getFaviconUrl(design: PlanDesign): string {
  return design === "coral" ? coralFavicon : design === "chonk" ? chonkFavicon : evaFavicon
}

export function updateFavicon(design: PlanDesign): void {
  if (typeof document === "undefined") return
  const iconLink = document.querySelector('link[rel="icon"]') as HTMLLinkElement | null
  if (iconLink) {
    iconLink.type = "image/png"
    iconLink.href = getFaviconUrl(design)
  }
}

export function applyPlanDesign(
  design: PlanDesign,
  evaTheme: EvaTheme = defaultEvaTheme,
  persist = true
): { design: PlanDesign; theme: "dark" | "light" } {
  const validDesign: PlanDesign = isPlanDesign(design) ? design : defaultPlanDesign
  const validEvaTheme: EvaTheme = isEvaTheme(evaTheme) ? evaTheme : defaultEvaTheme

  const theme: "dark" | "light" =
    validDesign === "coral"
      ? "light"
      : validDesign === "chonk"
        ? "dark"
        : validEvaTheme

  if (typeof document !== "undefined") {
    document.documentElement.dataset.design = validDesign
    document.documentElement.dataset.theme = theme
    updateFavicon(validDesign)
  }

  if (persist) {
    writeStoredPlanDesign(validDesign)
  }

  return { design: validDesign, theme }
}

export function applyEvaTheme(theme: EvaTheme, persist = true): EvaTheme {
  const validTheme: EvaTheme = isEvaTheme(theme) ? theme : defaultEvaTheme

  if (typeof document !== "undefined") {
    if (document.documentElement.dataset.design === "eva-01") {
      document.documentElement.dataset.theme = validTheme
    }
  }

  if (persist) {
    writeStoredEvaTheme(validTheme)
  }

  return validTheme
}

// ---------------------------------------------------------------------------
// Legacy Matcha Map / 18 Flat Themes Compatibility
// ---------------------------------------------------------------------------
export const defaultTheme = "catppuccin-latte"
export const planThemeStorageKey = "matcha-plan-theme"
export const mapThemeStorageKey = "matcha-map-theme"

export const themes = [
  { id: "catppuccin-latte", label: "Catppuccin Latte" },
  { id: "catppuccin", label: "Catppuccin" },
  { id: "dracula", label: "Dracula" },
  { id: "gruvbox", label: "Gruvbox" },
  { id: "gruvbox-light", label: "Gruvbox Light" },
  { id: "kanagawa", label: "Kanagawa" },
  { id: "kanagawa-lotus", label: "Kanagawa Lotus" },
  { id: "nord", label: "Nord" },
  { id: "one-dark", label: "One Dark" },
  { id: "one-light", label: "One Light" },
  { id: "rose-pine", label: "Rose Pine" },
  { id: "rose-pine-dawn", label: "Rose Pine Dawn" },
  { id: "solarized", label: "Solarized" },
  { id: "solarized-light", label: "Solarized Light" },
  { id: "terminal", label: "Terminal" },
  { id: "tokyo-night", label: "Tokyo Night" },
  { id: "tokyo-night-day", label: "Tokyo Night Day" },
  { id: "vesper", label: "Vesper" },
] as const

export type ThemeId = (typeof themes)[number]["id"]

export function isThemeId(value: string | null): value is ThemeId {
  return themes.some((theme) => theme.id === value)
}

export function readStoredTheme(storageKey: string): ThemeId {
  try {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem(storageKey)
      if (isThemeId(saved)) {
        return saved
      }
    }
  } catch {}

  return defaultTheme
}

export function writeStoredTheme(storageKey: string, theme: ThemeId): void {
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(storageKey, theme)
    }
  } catch {}
}

export function applyTheme(theme: ThemeId): void {
  if (typeof document !== "undefined") {
    document.documentElement.setAttribute("data-theme", theme)
  }
}
