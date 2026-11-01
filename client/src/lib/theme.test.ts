import { describe, it, expect, beforeEach } from "vitest"
import {
  defaultPlanDesign,
  defaultEvaTheme,
  planDesignStorageKey,
  evaThemeStorageKey,
  isPlanDesign,
  isEvaTheme,
  readStoredPlanDesign,
  writeStoredPlanDesign,
  readStoredEvaTheme,
  writeStoredEvaTheme,
  getFaviconSvg,
  updateFavicon,
  applyPlanDesign,
  applyEvaTheme,
  themes,
  defaultTheme,
  readStoredTheme,
  isThemeId,
} from "./theme"

describe("theme and design system", () => {
  let mockStorage: Record<string, string>
  let mockDataset: Record<string, string>
  let mockIconLink: { rel: string; href: string } | null

  beforeEach(() => {
    mockStorage = {}
    mockDataset = {}
    mockIconLink = null

    // Mock localStorage
    const storage = {
      getItem: (key: string) => (key in mockStorage ? mockStorage[key] : null),
      setItem: (key: string, value: string) => {
        mockStorage[key] = String(value)
      },
      removeItem: (key: string) => {
        delete mockStorage[key]
      },
      clear: () => {
        mockStorage = {}
      },
    }

    // @ts-expect-error global mock
    globalThis.localStorage = storage

    // Mock document
    const docElement = {
      dataset: mockDataset,
      setAttribute: (key: string, value: string) => {
        mockDataset[key.replace("data-", "")] = value
      },
      removeAttribute: (key: string) => {
        delete mockDataset[key.replace("data-", "")]
      },
    }

    // @ts-expect-error global mock
    globalThis.document = {
      documentElement: docElement,
      querySelector: (selector: string) => {
        if (selector === 'link[rel="icon"]') {
          return mockIconLink
        }
        return null
      },
    }
  })

  describe("defaults and guards", () => {
    it("has expected defaults and storage keys", () => {
      expect(defaultPlanDesign).toBe("coral")
      expect(defaultEvaTheme).toBe("dark")
      expect(planDesignStorageKey).toBe("matcha-plan-design")
      expect(evaThemeStorageKey).toBe("matcha-eva-theme")
    })

    it("validates plan designs", () => {
      expect(isPlanDesign("coral")).toBe(true)
      expect(isPlanDesign("mistral")).toBe(true)
      expect(isPlanDesign("eva-01")).toBe(true)
      expect(isPlanDesign("unknown")).toBe(false)
      expect(isPlanDesign(null)).toBe(false)
      expect(isPlanDesign(undefined)).toBe(false)
    })

    it("validates eva themes", () => {
      expect(isEvaTheme("dark")).toBe(true)
      expect(isEvaTheme("light")).toBe(true)
      expect(isEvaTheme("blue")).toBe(false)
      expect(isEvaTheme(null)).toBe(false)
      expect(isEvaTheme(undefined)).toBe(false)
    })
  })

  describe("storage persistence", () => {
    it("reads stored plan design with fallback to coral", () => {
      expect(readStoredPlanDesign()).toBe("coral")
      writeStoredPlanDesign("mistral")
      expect(readStoredPlanDesign()).toBe("mistral")
      localStorage.setItem(planDesignStorageKey, "invalid")
      expect(readStoredPlanDesign()).toBe("coral")
    })

    it("reads stored eva theme with fallback to dark", () => {
      expect(readStoredEvaTheme()).toBe("dark")
      writeStoredEvaTheme("light")
      expect(readStoredEvaTheme()).toBe("light")
      localStorage.setItem(evaThemeStorageKey, "invalid")
      expect(readStoredEvaTheme()).toBe("dark")
    })
  })

  describe("favicon generation", () => {
    it("generates design-specific dynamic svg favicons", () => {
      const coralSvg = getFaviconSvg("coral")
      expect(coralSvg).toContain("rx=\"10\"")
      expect(coralSvg).toContain("fill=\"#f5f3ef\"")
      expect(coralSvg).toContain("fill=\"#ff806e\"")

      const mistralSvg = getFaviconSvg("mistral")
      expect(mistralSvg).toContain("rx=\"4\"")
      expect(mistralSvg).toContain("fill=\"#0b0b12\"")
      expect(mistralSvg).toContain("fill=\"#ff8200\"")

      const evaSvg = getFaviconSvg("eva-01")
      expect(evaSvg).toContain("rx=\"0\"")
      expect(evaSvg).toContain("fill=\"#0d0d13\"")
      expect(evaSvg).toContain("fill=\"#bdff39\"")
    })

    it("updates existing link[rel=icon] href in DOM", () => {
      mockIconLink = { rel: "icon", href: "" }
      updateFavicon("coral")
      expect(mockIconLink.href).toContain("data:image/svg+xml")
      expect(decodeURIComponent(mockIconLink.href)).toContain("rx=\"10\"")
    })
  })

  describe("applyPlanDesign and applyEvaTheme transitions", () => {
    it("applies coral design forcing light theme", () => {
      const result = applyPlanDesign("coral", "dark")
      expect(result.design).toBe("coral")
      expect(result.theme).toBe("light")
      expect(mockDataset.design).toBe("coral")
      expect(mockDataset.theme).toBe("light")
      expect(localStorage.getItem(planDesignStorageKey)).toBe("coral")
    })

    it("applies mistral design forcing dark theme", () => {
      const result = applyPlanDesign("mistral", "light")
      expect(result.design).toBe("mistral")
      expect(result.theme).toBe("dark")
      expect(mockDataset.design).toBe("mistral")
      expect(mockDataset.theme).toBe("dark")
      expect(localStorage.getItem(planDesignStorageKey)).toBe("mistral")
    })

    it("applies eva-01 with specified evaTheme", () => {
      const darkResult = applyPlanDesign("eva-01", "dark")
      expect(darkResult.design).toBe("eva-01")
      expect(darkResult.theme).toBe("dark")
      expect(mockDataset.design).toBe("eva-01")
      expect(mockDataset.theme).toBe("dark")

      const lightResult = applyPlanDesign("eva-01", "light")
      expect(lightResult.design).toBe("eva-01")
      expect(lightResult.theme).toBe("light")
      expect(mockDataset.design).toBe("eva-01")
      expect(mockDataset.theme).toBe("light")
    })

    it("falls back to default design on unknown input", () => {
      // @ts-expect-error testing invalid input
      const result = applyPlanDesign("nonexistent")
      expect(result.design).toBe("coral")
      expect(result.theme).toBe("light")
    })

    it("toggles evaTheme via applyEvaTheme when eva-01 is active", () => {
      applyPlanDesign("eva-01", "dark")
      expect(mockDataset.theme).toBe("dark")

      applyEvaTheme("light")
      expect(mockDataset.theme).toBe("light")
      expect(localStorage.getItem(evaThemeStorageKey)).toBe("light")

      applyEvaTheme("dark")
      expect(mockDataset.theme).toBe("dark")
      expect(localStorage.getItem(evaThemeStorageKey)).toBe("dark")
    })

    it("does not overwrite document theme if active design is not eva-01", () => {
      applyPlanDesign("coral")
      expect(mockDataset.theme).toBe("light")

      applyEvaTheme("dark")
      // coral remains light, but storage is updated
      expect(mockDataset.theme).toBe("light")
      expect(localStorage.getItem(evaThemeStorageKey)).toBe("dark")
    })
  })

  describe("map backward compatibility", () => {
    it("preserves 18 flat themes and legacy functions", () => {
      expect(themes.length).toBe(18)
      expect(defaultTheme).toBe("catppuccin-latte")
      expect(isThemeId("catppuccin-latte")).toBe(true)
      expect(isThemeId("non-existent")).toBe(false)
      expect(readStoredTheme("map-theme")).toBe("catppuccin-latte")
    })
  })
})
