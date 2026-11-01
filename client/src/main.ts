import App from "./App.svelte"
import { mount } from "svelte"
import type { Plan } from "../../src/plan.ts"

declare global {
  interface Window {
    PLAN_DATA?: Plan
    plan?: Plan
  }
}

function readPlan(): Plan {
  if (window.PLAN_DATA) {
    return window.PLAN_DATA
  }

  if (window.plan) {
    return window.plan
  }

  const planElement = document.getElementById("plan-data")

  if (planElement?.textContent) {
    return JSON.parse(planElement.textContent) as Plan
  }

  throw new Error("Plan data was not found")
}

const target = document.getElementById("plan-root") ?? document.body

mount(App, {
  target,
  props: {
    plan: readPlan(),
  },
})
