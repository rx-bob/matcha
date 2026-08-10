<script lang="ts">
  import type { Plan } from "../../../../src/plan.ts"
  import OverviewSection from "./OverviewSection.svelte"
  import FileTreeSection from "../filetree/FileTreeSection.svelte"
  import EpicsSection from "./EpicsSection.svelte"
  import SectionsSection from "./SectionsSection.svelte"
  import WorkflowsSection from "./WorkflowsSection.svelte"
  import CommandsSection from "./CommandsSection.svelte"
  import RecommendedOrderSection from "./RecommendedOrderSection.svelte"
  import ExitCriteriaSection from "./ExitCriteriaSection.svelte"

  export let plan: Plan
</script>

<OverviewSection {plan} />

{#if plan.changedFiles && plan.changedFiles.length > 0}
  <FileTreeSection changedFiles={plan.changedFiles} />
{/if}

<EpicsSection epics={plan.epics} />

<SectionsSection sections={plan.sections} />

<WorkflowsSection workflows={plan.workflows} />

<CommandsSection commands={plan.commands} />

<RecommendedOrderSection items={plan.recommendedOrder} />

<ExitCriteriaSection criteria={plan.exitCriteria} />
