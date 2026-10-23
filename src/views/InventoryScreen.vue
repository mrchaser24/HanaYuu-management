<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import { getInventory, recordRestock } from '../lib/api'
import { formatDateTime, formatQuantity } from '../lib/datetime'
import { formatPeso, parsePesoInput } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useUiStore } from '../stores/ui'
import type { InventoryResponse } from '../lib/types'

const auth = useAuthStore()
const ui = useUiStore()

const inventory = ref<InventoryResponse | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const activeTab = ref<'ingredients' | 'finished' | 'movements'>('ingredients')
const showRestock = ref(false)
const supplier = ref('')
const note = ref('')
const restockLines = ref<Array<{ ingredient_id: string; quantity: string; unit_cost: string }>>([])
const busy = ref(false)
const formError = ref<string | null>(null)

const ingredients = computed(() => inventory.value?.ingredients ?? [])
const finishedGoods = computed(() => inventory.value?.finished_goods ?? [])
const movements = computed(() => inventory.value?.movements ?? [])
const lowStock = computed(() => ingredients.value.filter((item) => item.is_low))
const ingredientValue = computed(() => ingredients.value.reduce((sum, item) => sum + item.value_centavos, 0))
const finishedValue = computed(() => finishedGoods.value.reduce((sum, item) => sum + item.value_centavos, 0))
const draftTotal = computed(() =>
  restockLines.value.reduce(
    (sum, line) => sum + Math.round((Number(line.quantity) || 0) * parsePesoInput(line.unit_cost)),
    0,
  ),
)

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    inventory.value = await getInventory(auth.activeBranchId)
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
    inventory.value = null
  } finally {
    loading.value = false
  }
}

function openRestock() {
  showRestock.value = true
  supplier.value = ''
  note.value = ''
  formError.value = null
  restockLines.value = [
    { ingredient_id: ingredients.value[0]?.id ?? '', quantity: '', unit_cost: '' },
  ]
}

function addLine() {
  restockLines.value.push({ ingredient_id: ingredients.value[0]?.id ?? '', quantity: '', unit_cost: '' })
}

function removeLine(index: number) {
  restockLines.value.splice(index, 1)
  if (!restockLines.value.length) addLine()
}

async function submitRestock() {
  if (!auth.activeBranchId) return
  formError.value = null
  const items = restockLines.value
    .filter((line) => line.ingredient_id && Number(line.quantity) > 0)
    .map((line) => ({
      ingredient_id: line.ingredient_id,
      quantity: Number(line.quantity),
      unit_cost_centavos: parsePesoInput(line.unit_cost),
    }))
  if (!items.length) {
    formError.value = 'Add at least one ingredient with a quantity.'
    return
  }
  busy.value = true
  try {
    await recordRestock({
      branchId: auth.activeBranchId,
      requestId: crypto.randomUUID(),
      supplier: supplier.value,
      note: note.value,
      items,
    })
    showRestock.value = false
    ui.success('Stock received', 'Ingredient balances and average costs were updated.')
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function ingredientName(id: string) {
  return ingredients.value.find((item) => item.id === id)?.name ?? 'Ingredient'
}

function unitFor(id: string) {
  return ingredients.value.find((item) => item.id === id)?.base_unit ?? ''
}

function movementLabel(kind: string) {
  return kind.replaceAll('_', ' ')
}

onMounted(() => void load())
watch(() => auth.activeBranchId, () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Inventory</h1>
        <p class="subtle">Raw ingredients, prepared stock, and every movement.</p>
      </div>
      <div class="heading-actions">
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
        <button type="button" class="primary small" :disabled="!ingredients.length" @click="openRestock">Receive stock</button>
      </div>
    </div>

    <div class="summary-strip">
      <article class="summary-card"><span>Ingredient value</span><strong>{{ formatPeso(ingredientValue) }}</strong></article>
      <article class="summary-card"><span>Prepared goods</span><strong>{{ formatPeso(finishedValue) }}</strong></article>
      <article class="summary-card" :class="{ attention: lowStock.length }"><span>Low stock</span><strong>{{ lowStock.length }}</strong></article>
      <article class="summary-card"><span>Ingredients tracked</span><strong>{{ ingredients.length }}</strong></article>
    </div>

    <div v-if="lowStock.length" class="callout warning">
      <strong>Running low:</strong> {{ lowStock.map((item) => item.name).join(', ') }}.
      <button type="button" class="text-link" @click="openRestock">Receive stock</button>
    </div>
    <div v-if="error" class="callout danger">{{ error }}</div>

    <div class="tabs" role="tablist">
      <button type="button" :class="{ active: activeTab === 'ingredients' }" @click="activeTab = 'ingredients'">Ingredients</button>
      <button type="button" :class="{ active: activeTab === 'finished' }" @click="activeTab = 'finished'">Finished goods</button>
      <button type="button" :class="{ active: activeTab === 'movements' }" @click="activeTab = 'movements'">Movements</button>
    </div>

    <div v-if="loading && !inventory" class="panel loading-panel">Loading inventory…</div>
    <template v-else>
      <div v-if="activeTab === 'ingredients'" class="panel table-panel">
        <div v-if="!ingredients.length" class="empty-panel"><h2>No ingredients yet</h2><p>An owner can add ingredients in Admin.</p></div>
        <div v-else class="data-table six-col">
          <div class="table-head"><span>Ingredient</span><span>On hand</span><span>Low at</span><span>Avg cost</span><span>Value</span><span>Status</span></div>
          <div v-for="item in ingredients" :key="item.id" class="table-row static">
            <span><b>{{ item.name }}</b><small>{{ item.category || 'Uncategorised' }}</small></span>
            <span class="amount">{{ formatQuantity(item.quantity, item.base_unit) }}</span>
            <span>{{ formatQuantity(item.low_stock_quantity, item.base_unit) }}</span>
            <span>{{ formatPeso(Math.round(item.average_cost_centavos)) }}<small>/ {{ item.base_unit }}</small></span>
            <span class="amount">{{ formatPeso(item.value_centavos) }}</span>
            <span><span class="status-badge" :class="item.is_low ? 'needs_review' : 'completed'">{{ item.is_low ? 'Low' : 'OK' }}</span></span>
          </div>
        </div>
      </div>

      <div v-else-if="activeTab === 'finished'" class="panel table-panel">
        <div v-if="!finishedGoods.length" class="empty-panel"><h2>No batch products</h2><p>Batch-produced menu items appear here after setup.</p></div>
        <div v-else class="data-table four-col">
          <div class="table-head"><span>Prepared item</span><span>On hand</span><span>Avg cost</span><span>Value</span></div>
          <div v-for="item in finishedGoods" :key="item.product_id" class="table-row static">
            <span><b>{{ item.name }}</b><small>Batch produced</small></span>
            <span class="amount">{{ formatQuantity(item.quantity) }}</span>
            <span>{{ formatPeso(Math.round(item.average_cost_centavos)) }}</span>
            <span class="amount">{{ formatPeso(item.value_centavos) }}</span>
          </div>
        </div>
      </div>

      <div v-else class="panel">
        <div v-if="!movements.length" class="empty-panel"><h2>No movements yet</h2><p>Restocks, sales, and production will appear here.</p></div>
        <div v-else class="movement-list">
          <div v-for="movement in movements" :key="movement.id" class="movement-item">
            <div class="movement-icon" :class="{ positive: movement.quantity_delta > 0, negative: movement.quantity_delta < 0 }">
              {{ movement.quantity_delta > 0 ? '+' : '−' }}
            </div>
            <div>
              <strong>{{ movement.ingredient_name ?? movement.product_name ?? 'Stock' }}</strong>
              <small>{{ movementLabel(movement.kind) }} · {{ formatDateTime(movement.created_at) }} · {{ movement.actor_name ?? 'System' }}</small>
            </div>
            <div class="movement-amount">
              <b>{{ movement.quantity_delta > 0 ? '+' : '' }}{{ formatQuantity(movement.quantity_delta) }}</b>
              <small>{{ formatPeso(Math.round(movement.unit_cost_centavos)) }}</small>
            </div>
          </div>
        </div>
      </div>
    </template>

    <AppModal v-if="showRestock" title="Receive stock" subtitle="Quantities use each ingredient's base unit." wide @close="showRestock = false">
      <form class="form-stack" @submit.prevent="submitRestock">
        <div class="two-column">
          <label><span>Supplier</span><input v-model="supplier" maxlength="120" placeholder="Optional supplier" /></label>
          <label><span>Reference / note</span><input v-model="note" maxlength="200" placeholder="Optional note" /></label>
        </div>
        <div class="restock-lines">
          <div v-for="(line, index) in restockLines" :key="index" class="restock-line">
            <label>
              <span>Ingredient</span>
              <select v-model="line.ingredient_id">
                <option v-for="item in ingredients" :key="item.id" :value="item.id">{{ item.name }}</option>
              </select>
            </label>
            <label>
              <span>Quantity ({{ unitFor(line.ingredient_id) }})</span>
              <input v-model="line.quantity" inputmode="decimal" placeholder="0" />
            </label>
            <label>
              <span>Cost per {{ unitFor(line.ingredient_id) }} (₱)</span>
              <input v-model="line.unit_cost" inputmode="decimal" placeholder="0.00" />
            </label>
            <button type="button" class="icon-button" aria-label="Remove row" @click="removeLine(index)">×</button>
          </div>
        </div>
        <div class="inline-links">
          <button type="button" class="text-link" @click="addLine">+ Add another ingredient</button>
          <span class="draft-total">Draft total <b>{{ formatPeso(draftTotal) }}</b></span>
        </div>
        <p class="form-note">
          Current draft: {{ restockLines.map((line) => `${ingredientName(line.ingredient_id)} ${line.quantity || 0}`).join(' · ') }}.
        </p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showRestock = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Posting…' : 'Post restock' }}</button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
