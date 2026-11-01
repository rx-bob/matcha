<script lang="ts">
  import type { Plan } from "../../../../src/plan.ts"
  import OverviewSection from "./OverviewSection.svelte"
  import FileTreeSection from "../filetree/FileTreeSection.svelte"
  import EpicsSection from "./EpicsSection.svelte"
  import SectionsSection from "./SectionsSection.svelte"
  import RecommendedOrderSection from "./RecommendedOrderSection.svelte"
  import ExitCriteriaSection from "./ExitCriteriaSection.svelte"

  export let plan: Plan
  export let currentView = "overview"
</script>

<OverviewSection {plan} hidden={currentView !== "overview"} />

<section class="page-view" id="view-epics" data-view="epics" hidden={currentView !== "epics"}>
  <header class="page-heading">
    <h1>Implementation plan</h1>
  </header>
  <EpicsSection epics={plan.epics} />
</section>

<section class="page-view" id="view-files" data-view="files" hidden={currentView !== "files"}>
  <header class="page-heading">
    <h1>Project files</h1>
  </header>
  <FileTreeSection changedFiles={plan.changedFiles ?? []} />
</section>

<SectionsSection sections={plan.sections} hidden={currentView !== "context"} />

<RecommendedOrderSection
  items={plan.recommendedOrder}
  epics={plan.epics}
  hidden={currentView !== "order"}
/>

<ExitCriteriaSection criteria={plan.exitCriteria} hidden={currentView !== "criteria"} />
