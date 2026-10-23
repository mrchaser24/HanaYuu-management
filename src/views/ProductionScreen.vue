<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import { getProductionBatches, postProductionBatch } from '../lib/api'
import { formatDateTime, formatQuantity } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore } from '../stores/catalog'
import { useUiStore } from '../stores/ui'
import type { ProductionBatch } from '../lib/types'

const auth = useAuthStore()
const catalog = useCatalogStore()
const ui = useUiStore()

const batches = ref<ProductionBatch[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const showForm = ref(false)
const selectedProductId = ref('')
const actualYield = ref('')
const wasteQuantity = ref('0')
const wasteReason = ref('')
const busy = ref(false)
const formError = ref<string | null>(null)

const batchProducts = computed(() => catalog.products.filter((product) => product.stock_model === 'batch_produced'))
const selectedProduct = computed(() => batchProducts.value.find((product) => product.id === selectedProductId.value) ?? null)
const recentBatches = computed(() => batches.value)
const totalWaste = computed(() => batches.value.reduce((sum, batch) => sum + Number(batch.waste_quantity), 0))
const totalCost = computed(() => batches.value.reduce((sum, batch) => sum + batch.total_cost_centavos, 0))

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    await catalog.load(auth.activeBranchId)
    batches.value = await getProductionBatches(auth.activeBranchId)
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
  } finally {
    loading.value = false
  }
}

function openForm() {
  showForm.value = true
  selectedProductId.value = batchProducts.value[0]?.id ?? ''
  actualYield.value = String(batchProducts.value[0]?.expected_yield_quantity ?? '')
  wasteQuantity.value = '0'
  wasteReason.value = ''
  formError.value = null
}

async function submit() {
  if (!auth.activeBranchId || !selectedProduct.value) return
  formError.value = null
  busy.value = true
  try {
    await postProductionBatch({
      branchId: auth.activeBranchId,
      productId: selectedProduct.value.id,
      requestId: crypto.randomUUID(),
      actualYield: Number(actualYield.value),
      wasteQuantity: Number(wasteQuantity.value) || 0,
      wasteReason: wasteReason.value,
    })
    showForm.value = false
    ui.success('Production posted', 'Ingredient stock was consumed and finished goods were added.')
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function variance(batch: ProductionBatch) {
  return Number(batch.actual_yield) - Number(batch.expected_yield)
}

onMounted(() => void load())
watch(() => auth.activeBranchId, () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Production</h1>
        <p class="subtle">Turn ingredients into prepared batches with a clear cost trail.</p>
      </div>
      <div class="heading-actions">
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
        <button type="button" class="primary small" :disabled="!batchProducts.length" @click="openForm">Post a batch</button>
      </div>
    </div>

    <div class="summary-strip">
      <article class="summary-card"><span>Batches shown</span><strong>{{ recentBatches.length }}</strong></article>
      <article class="summary-card"><span>Recorded waste</span><strong>{{ formatQuantity(totalWaste) }}</strong></article>
      <article class="summary-card"><span>Production cost</span><strong>{{ formatPeso(totalCost) }}</strong></article>
      <article class="summary-card"><span>Batch products</span><strong>{{ batchProducts.length }}</strong></article>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>
    <div v-if="!batchProducts.length" class="callout warning">
      No batch-produced products are configured. An owner can mark a product as batch-produced in Admin.
    </div>

    <div class="panel table-panel">
      <div class="panel-title">
        <div><p class="eyebrow">Production log</p><h2>Recent batches</h2></div>
      </div>
      <div v-if="loading && !batches.length" class="loading-panel">Loading batches…</div>
      <div v-else-if="!batches.length" class="empty-panel">
        <h2>No batches posted</h2>
        <p>Post your first batch after preparing stock.</p>
        <button type="button" class="primary" :disabled="!batchProducts.length" @click="openForm">Post a batch</button>
      </div>
      <div v-else class="data-table six-col">
        <div class="table-head"><span>Product</span><span>Prepared</span><span>Yield</span><span>Waste</span><span>Cost</span><span>By</span></div>
        <div v-for="batch in batches" :key="batch.id" class="table-row static">
          <span><b>{{ batch.product_name }}</b><small>{{ formatDateTime(batch.created_at) }}</small></span>
          <span>{{ formatDateTime(batch.posted_at) }}</span>
          <span>
            <b>{{ formatQuantity(batch.actual_yield) }}</b>
            <small :class="variance(batch) < 0 ? 'negative-text' : 'positive-text'">
              {{ variance(batch) > 0 ? '+' : '' }}{{ formatQuantity(variance(batch)) }} vs expected
            </small>
          </span>
          <span>{{ formatQuantity(batch.waste_quantity) }}<small>{{ batch.waste_reason || 'No reason' }}</small></span>
          <span>{{ formatPeso(batch.total_cost_centavos) }}<small>{{ formatPeso(Math.round(batch.cost_per_unit_centavos)) }} / unit</small></span>
          <span>{{ batch.prepared_by_name ?? '—' }}</span>
        </div>
      </div>
    </div>

    <AppModal v-if="showForm" title="Post production batch" subtitle="This consumes recipe ingredients and adds finished stock." @close="showForm = false">
      <form class="form-stack" @submit.prevent="submit">
        <label>
          <span>Batch product</span>
          <select v-model="selectedProductId" @change="actualYield = String(selectedProduct?.expected_yield_quantity ?? '')">
            <option v-for="product in batchProducts" :key="product.id" :value="product.id">
              {{ product.name }}{{ product.recipe_complete ? '' : ' · recipe incomplete' }}
            </option>
          </select>
        </label>
        <div v-if="selectedProduct && !selectedProduct.recipe_complete" class="callout warning">
          This product has no recipe yet. Add one in Admin before producing it.
        </div>
        <div class="two-column">
          <label>
            <span>Actual yield ({{ selectedProduct?.expected_yield_unit ?? 'serving' }})</span>
            <input v-model="actualYield" inputmode="decimal" min="0" step="0.001" required />
          </label>
          <label>
            <span>Waste quantity</span>
            <input v-model="wasteQuantity" inputmode="decimal" min="0" step="0.001" />
          </label>
        </div>
        <label>
          <span>Waste reason</span>
          <input v-model="wasteReason" maxlength="200" placeholder="Optional, required when waste is recorded" />
        </label>
        <p class="form-note">
          Expected yield: {{ formatQuantity(selectedProduct?.expected_yield_quantity ?? 0, selectedProduct?.expected_yield_unit) }}.
          Ingredients are checked before anything is posted.
        </p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showForm = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy || !selectedProduct?.recipe_complete">
            {{ busy ? 'Posting…' : 'Post batch' }}
          </button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
