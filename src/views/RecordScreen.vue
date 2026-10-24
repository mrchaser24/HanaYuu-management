<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore } from '../stores/catalog'
import { useUiStore } from '../stores/ui'
import { formatPeso, parsePesoInput, centavosToPesos, formatPesoInput } from '../lib/money'
import { formatDateTime } from '../lib/datetime'
import {
  recordRestock,
  recordExpense,
  recordInventoryAdjustment,
  postProductionBatch,
  openShift,
  closeShift,
  getCashShifts,
  getInventory,
} from '../lib/api'
import type { CashShift, Ingredient, InventoryResponse } from '../lib/types'

const auth = useAuthStore()
const catalog = useCatalogStore()
const ui = useUiStore()

// ── Tabs ──

type Tab = 'stock' | 'restock' | 'expense' | 'produce' | 'cash' | 'adjustment'
const activeTab = ref<Tab>('stock')

// ── Helpers ──

function localDateTimeInput(date: Date) {
  const offset = date.getTimezoneOffset()
  return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 16)
}

// ── Shared data ──

const inventory = ref<InventoryResponse | null>(null)
const shifts = ref<CashShift[]>([])
const dataLoading = ref(false)

async function loadData() {
  const branchId = auth.activeBranchId
  if (!branchId) return
  dataLoading.value = true
  try {
    const [inv, sh] = await Promise.all([
      getInventory(branchId),
      getCashShifts(branchId, 20),
    ])
    inventory.value = inv
    shifts.value = sh
  } catch (e) {
    // silent – individual forms show their own errors
  } finally {
    dataLoading.value = false
  }
}

onMounted(async () => {
  const branchId = auth.activeBranchId
  if (branchId) {
    await catalog.load(branchId)
    await loadData()
  }
})

watch(() => auth.activeBranchId, async (id) => {
  if (id) {
    await catalog.load(id)
    await loadData()
  }
})

// ── Restock form ──

interface RestockLine {
  ingredientId: string
  quantity: string
  totalCost: string
  unitCost: string
}

const restockLines = ref<RestockLine[]>([{ ingredientId: '', quantity: '', totalCost: '', unitCost: '' }])
const restockSupplier = ref('')
const restockNote = ref('')
const restockDeliveryFee = ref('')
const restockDate = ref(localDateTimeInput(new Date()))
const restockBusy = ref(false)
const restockError = ref('')

function addRestockLine() {
  restockLines.value.push({ ingredientId: '', quantity: '', totalCost: '', unitCost: '' })
}

function removeRestockLine(index: number) {
  if (restockLines.value.length > 1) restockLines.value.splice(index, 1)
}

function ingredientUnit(ingredientId: string): string {
  return inventory.value?.ingredients?.find((i: Ingredient) => i.id === ingredientId)?.base_unit || 'unit'
}

function recommendedUnitCostPesos(line: RestockLine): number {
  const qty = Number(line.quantity) || 0
  const totalCentavos = parsePesoInput(line.totalCost)
  return qty > 0 && totalCentavos > 0 ? centavosToPesos(totalCentavos) / qty : 0
}

function recomputeTotalFromUnit(line: RestockLine) {
  const qty = Number(line.quantity) || 0
  const unitCentavos = parsePesoInput(line.unitCost)
  if (qty > 0 && unitCentavos > 0) {
    line.totalCost = formatPesoInput(Math.round(qty * unitCentavos))
  }
}

async function submitRestock() {
  restockError.value = ''
  const branchId = auth.activeBranchId
  if (!branchId) { restockError.value = 'No active branch'; return }

  const items = restockLines.value.map((l) => {
    const qty = Number(l.quantity) || 0
    const totalCentavos = parsePesoInput(l.totalCost)
    const unitCostCentavos = l.unitCost && Number(l.unitCost) > 0
      ? parsePesoInput(l.unitCost)
      : qty > 0 ? Math.round(totalCentavos / qty) : 0
    return {
      ingredient_id: l.ingredientId,
      quantity: qty,
      unit_cost_centavos: unitCostCentavos,
    }
  })

  if (items.some((i) => !i.ingredient_id || i.quantity <= 0 || i.unit_cost_centavos <= 0)) {
    restockError.value = 'Fill in all line items (ingredient, quantity > 0, total cost > 0).'
    return
  }

  restockBusy.value = true
  try {
    await recordRestock({
      branchId,
      requestId: crypto.randomUUID(),
      supplier: restockSupplier.value.trim(),
      note: restockNote.value.trim(),
      items,
      deliveryFee: parsePesoInput(restockDeliveryFee.value) || undefined,
      paidFromCash: !!openShiftData.value,
      shiftId: openShiftData.value?.id ?? null,
    })
    ui.success('Restock recorded')
    restockLines.value = [{ ingredientId: '', quantity: '', totalCost: '', unitCost: '' }]
    restockSupplier.value = ''
    restockNote.value = ''
    restockDeliveryFee.value = ''
    restockDate.value = localDateTimeInput(new Date())
    await loadData()
  } catch (e: any) {
    restockError.value = e?.message ?? 'Failed to record restock'
  } finally {
    restockBusy.value = false
  }
}

// ── Expense form ──

const expenseCategories = ['Ingredients', 'Fuel', 'Utilities', 'Supplies', 'Rent', 'Delivery', 'Other']
const expenseCategory = ref('')
const expenseAmount = ref('')
const expenseDescription = ref('')
const expenseDeliveryFee = ref('')
const expenseDate = ref(localDateTimeInput(new Date()))
const expenseBusy = ref(false)
const expenseError = ref('')

async function submitExpense() {
  expenseError.value = ''
  const branchId = auth.activeBranchId
  if (!branchId) { expenseError.value = 'No active branch'; return }

  const amountCentavos = parsePesoInput(expenseAmount.value)
  if (!expenseCategory.value.trim()) { expenseError.value = 'Category is required.'; return }
  if (amountCentavos <= 0) { expenseError.value = 'Amount must be greater than 0.'; return }

  expenseBusy.value = true
  try {
    await recordExpense({
      branchId,
      category: expenseCategory.value.trim(),
      description: expenseDescription.value.trim(),
      amountCentavos,
      paidFromCash: !!openShiftData.value,
      cashMovementId: null,
      shiftId: openShiftData.value?.id ?? null,
      spentAt: new Date(expenseDate.value).toISOString(),
      deliveryFee: parsePesoInput(expenseDeliveryFee.value) || undefined,
    })
    ui.success('Expense recorded')
    expenseCategory.value = ''
    expenseAmount.value = ''
    expenseDescription.value = ''
    expenseDeliveryFee.value = ''
    expenseDate.value = localDateTimeInput(new Date())
    await loadData()
  } catch (e: any) {
    expenseError.value = e?.message ?? 'Failed to record expense'
  } finally {
    expenseBusy.value = false
  }
}

// ── Production form ──

const batchProducts = computed(() =>
  catalog.products.filter((p) => p.stock_model === 'batch_produced'),
)

const prodProductId = ref('')
const prodActualYield = ref('')
const prodWaste = ref('')
const prodWasteReason = ref('')
const prodBusy = ref(false)
const prodError = ref('')

// ── Adjustment form ──

const adjIngredientId = ref('')
const adjActualQuantity = ref('')
const adjReason = ref('')
const adjBusy = ref(false)
const adjError = ref('')

async function submitAdjustment() {
  adjError.value = ''
  const branchId = auth.activeBranchId
  if (!branchId) { adjError.value = 'No active branch'; return }
  if (!adjIngredientId.value) { adjError.value = 'Select an ingredient.'; return }

  const actualQuantity = Number(adjActualQuantity.value) || 0
  if (actualQuantity < 0) { adjError.value = 'Quantity must be 0 or greater.'; return }
  if (!adjReason.value.trim()) { adjError.value = 'Reason is required.'; return }

  adjBusy.value = true
  try {
    await recordInventoryAdjustment({
      branchId,
      ingredientId: adjIngredientId.value,
      actualQuantity,
      reason: adjReason.value.trim(),
    })
    ui.success('Inventory adjusted')
    adjIngredientId.value = ''
    adjActualQuantity.value = ''
    adjReason.value = ''
    await loadData()
  } catch (e: any) {
    adjError.value = e?.message ?? 'Failed to adjust inventory'
  } finally {
    adjBusy.value = false
  }
}

const selectedProduct = computed(() =>
  batchProducts.value.find((p) => p.id === prodProductId.value) ?? null,
)

async function submitProduction() {
  prodError.value = ''
  const branchId = auth.activeBranchId
  if (!branchId) { prodError.value = 'No active branch'; return }
  if (!prodProductId.value) { prodError.value = 'Select a product.'; return }

  const actualYield = Number(prodActualYield.value) || 0
  const wasteQuantity = Number(prodWaste.value) || 0
  if (actualYield <= 0) { prodError.value = 'Actual yield must be greater than 0.'; return }

  prodBusy.value = true
  try {
    await postProductionBatch({
      branchId,
      productId: prodProductId.value,
      requestId: crypto.randomUUID(),
      actualYield,
      wasteQuantity,
      wasteReason: prodWasteReason.value.trim(),
    })
    ui.success('Production batch recorded')
    prodProductId.value = ''
    prodActualYield.value = ''
    prodWaste.value = ''
    prodWasteReason.value = ''
    await loadData()
  } catch (e: any) {
    prodError.value = e?.message ?? 'Failed to record production'
  } finally {
    prodBusy.value = false
  }
}

// ── Cash form ──

const openShiftAmount = ref('')
const closeShiftNote = ref('')
const closeShiftCounted = ref('')
const cashBusy = ref(false)
const cashError = ref('')
const closeResult = ref<{ expected_cash_centavos: number; counted_cash_centavos: number; over_short_centavos: number } | null>(null)

const openShiftData = computed(() =>
  shifts.value.find((s) => s.status === 'open') ?? null,
)
const lastClosedShift = computed(() => {
  const closed = shifts.value.filter((s) => s.status === 'closed' && s.counted_cash_centavos !== null)
  return closed.length ? closed[0] : null
})
const cashOverview = computed(() => {
  const current = openShiftData.value?.current_expected_cash_centavos ?? 0
  const lastCounted = lastClosedShift.value?.counted_cash_centavos ?? 0
  return { currentExpected: current, lastCounted, hasOpen: Boolean(openShiftData.value) }
})

function prefillFromLastShift() {
  if (lastClosedShift.value?.counted_cash_centavos != null) {
    openShiftAmount.value = String(lastClosedShift.value.counted_cash_centavos / 100)
  }
}

async function submitOpenShift() {
  cashError.value = ''
  closeResult.value = null
  const branchId = auth.activeBranchId
  if (!branchId) { cashError.value = 'No active branch'; return }

  const centavos = parsePesoInput(openShiftAmount.value)
  if (centavos <= 0) { cashError.value = 'Opening cash must be greater than 0.'; return }

  cashBusy.value = true
  try {
    await openShift(branchId, centavos)
    ui.success('Shift opened')
    openShiftAmount.value = ''
    await loadData()
  } catch (e: any) {
    cashError.value = e?.message ?? 'Failed to open shift'
  } finally {
    cashBusy.value = false
  }
}

async function submitCloseShift() {
  cashError.value = ''
  closeResult.value = null
  const shift = openShiftData.value
  if (!shift) { cashError.value = 'No open shift to close.'; return }

  const counted = parsePesoInput(closeShiftCounted.value)
  if (counted < 0) { cashError.value = 'Counted cash is required.'; return }

  cashBusy.value = true
  try {
    const result = await closeShift(shift.id, counted, closeShiftNote.value.trim())
    closeResult.value = result
    ui.success('Shift closed')
    closeShiftCounted.value = ''
    closeShiftNote.value = ''
    await loadData()
  } catch (e: any) {
    cashError.value = e?.message ?? 'Failed to close shift'
  } finally {
    cashBusy.value = false
  }
}
</script>

<template>
  <div style="padding: 18px; max-width: 640px; margin: 0 auto;">
    <h1>Record</h1>

    <div class="tabs">
      <button :class="{ active: activeTab === 'stock' }" @click="activeTab = 'stock'">Stock</button>
      <button :class="{ active: activeTab === 'restock' }" @click="activeTab = 'restock'">Restock</button>
      <button :class="{ active: activeTab === 'expense' }" @click="activeTab = 'expense'">Expense</button>
      <button :class="{ active: activeTab === 'produce' }" @click="activeTab = 'produce'">Produce</button>
      <button :class="{ active: activeTab === 'cash' }" @click="activeTab = 'cash'">Cash</button>
      <button :class="{ active: activeTab === 'adjustment' }" @click="activeTab = 'adjustment'">Adjustment</button>
    </div>

    <!-- ── STOCK TAB ── -->
    <div v-if="activeTab === 'stock'">
      <div v-if="dataLoading" class="panel">Loading stock data…</div>
      <template v-else-if="inventory">
        <div class="metric-grid" style="margin-bottom:14px">
          <article class="metric-card accent">
            <span>Ingredient value</span>
            <strong>{{ formatPeso(inventory.ingredients.reduce((s, i) => s + (i.value_centavos || 0), 0)) }}</strong>
            <small>{{ inventory.ingredients.length }} tracked</small>
          </article>
          <article class="metric-card">
            <span>Finished goods</span>
            <strong>{{ formatPeso(inventory.finished_goods.reduce((s, f) => s + (f.value_centavos || 0), 0)) }}</strong>
            <small>{{ inventory.finished_goods.length }} products</small>
          </article>
          <article class="metric-card">
            <span>Low stock</span>
            <strong>{{ inventory.ingredients.filter(i => i.is_low).length }}</strong>
            <small>items below threshold</small>
          </article>
        </div>

        <article class="panel" style="margin-bottom:14px">
          <div class="panel-title"><h2>Ingredients on hand</h2></div>
          <div v-if="!inventory.ingredients.length" class="empty-state">No ingredients tracked yet. Add ingredients in Settings → Admin → Ingredients.</div>
          <div v-else class="data-table">
            <div class="table-head"><span>Ingredient</span><span>Quantity</span><span>Avg cost</span><span>Value</span><span></span></div>
            <div v-for="ing in inventory.ingredients" :key="ing.id" class="table-row static" :class="{ 'low-stock-row': ing.is_low }">
              <span><b>{{ ing.name }}</b><small>{{ ing.base_unit }}</small></span>
              <span>{{ Number(ing.quantity).toFixed(ing.base_unit === 'piece' ? 0 : 2) }} {{ ing.base_unit }}</span>
              <span>{{ formatPeso(ing.average_cost_centavos || 0) }}/{{ ing.base_unit }}</span>
              <span>{{ formatPeso(ing.value_centavos || 0) }}</span>
              <span><span v-if="ing.is_low" class="status-badge rejected">Low</span></span>
            </div>
          </div>
        </article>

        <article v-if="inventory.finished_goods.length" class="panel" style="margin-bottom:14px">
          <div class="panel-title"><h2>Finished goods</h2></div>
          <div class="data-table">
            <div class="table-head"><span>Product</span><span>Quantity</span><span>Avg cost</span><span>Value</span></div>
            <div v-for="fg in inventory.finished_goods" :key="fg.product_id" class="table-row static">
              <span><b>{{ fg.name }}</b></span>
              <span>{{ Number(fg.quantity).toFixed(0) }}</span>
              <span>{{ formatPeso(fg.average_cost_centavos || 0) }}</span>
              <span>{{ formatPeso(fg.value_centavos || 0) }}</span>
            </div>
          </div>
        </article>

        <article class="panel">
          <div class="panel-title"><h2>Recent movements</h2></div>
          <div v-if="!inventory.movements.length" class="empty-state">No stock movements yet.</div>
          <div v-else class="activity-list">
            <div v-for="m in inventory.movements.slice(0, 25)" :key="m.id" class="activity-item">
              <div class="activity-icon" :class="m.kind">
                {{ m.kind === 'restock' ? '📦' : m.kind === 'sale_consumption' ? '🍗' : m.kind === 'production_consumption' ? '🔥' : m.kind === 'production_output' ? '✅' : '↩' }}
              </div>
              <div>
                <strong>{{ m.ingredient_name || m.product_name || 'Item' }}</strong>
                <small>{{ m.kind.replace(/_/g, ' ') }} · {{ m.actor_name || 'System' }} · {{ new Date(m.created_at).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) }}</small>
              </div>
              <div class="activity-amount" :class="Number(m.quantity_delta) >= 0 ? 'positive' : 'negative'">
                {{ Number(m.quantity_delta) >= 0 ? '+' : '' }}{{ Number(m.quantity_delta) }}
              </div>
            </div>
          </div>
        </article>
      </template>
      <div v-else class="panel empty-state">No inventory data. Assign a branch and add ingredients first.</div>
    </div>

    <!-- ── RESTOCK TAB ── -->
    <div v-if="activeTab === 'restock'" class="panel">
      <div class="panel-title"><h2>Restock Ingredients</h2></div>

      <div class="form-stack">
        <div
          v-for="(line, i) in restockLines"
          :key="i"
          class="two-column"
          style="align-items: end;"
        >
          <label>
            <span>Ingredient</span>
            <select v-model="line.ingredientId">
              <option value="" disabled>Select ingredient</option>
              <option
                v-for="ing in inventory?.ingredients ?? []"
                :key="ing.id"
                :value="ing.id"
              >{{ ing.name }} ({{ ing.base_unit }})</option>
            </select>
          </label>
          <label>
            <span>Quantity</span>
            <input v-model="line.quantity" type="number" min="0" step="any" placeholder="0" />
          </label>
          <label>
            <span>Total cost (₱)</span>
            <input v-model="line.totalCost" type="text" inputmode="decimal" placeholder="0.00" @input="line.unitCost = ''" />
            <small v-if="Number(line.quantity) > 0 && parsePesoInput(line.totalCost) > 0 && !line.unitCost" style="color:#65736b;font-size:11px">
              Recommended: ₱{{ recommendedUnitCostPesos(line).toFixed(2) }}/{{ ingredientUnit(line.ingredientId) }}
            </small>
          </label>
          <label>
            <span>Unit cost (₱/{{ ingredientUnit(line.ingredientId) }})</span>
            <input v-model="line.unitCost" type="text" inputmode="decimal" placeholder="0.00" @input="recomputeTotalFromUnit(line)" />
            <small v-if="line.unitCost && Number(line.quantity) > 0 && parsePesoInput(line.unitCost) > 0" style="color:#65736b;font-size:11px">
              Override → total ₱{{ (parsePesoInput(line.totalCost) / 100).toFixed(2) }}
            </small>
          </label>
          <button
            v-if="restockLines.length > 1"
            class="secondary small"
            type="button"
            @click="removeRestockLine(i)"
          >✕</button>
        </div>

        <button class="secondary small" type="button" @click="addRestockLine">+ Add item</button>

        <label>
          <span>Supplier</span>
          <input v-model="restockSupplier" type="text" placeholder="Supplier name" />
        </label>

        <label>
          <span>Note</span>
          <input v-model="restockNote" type="text" placeholder="Optional note" />
        </label>

        <label>
          <span>Delivery fee (₱)</span>
          <input v-model="restockDeliveryFee" type="text" inputmode="decimal" placeholder="0.00" />
        </label>

        <label>
          <span>Date purchased</span>
          <input v-model="restockDate" type="datetime-local" />
        </label>

        <p v-if="restockError" class="form-error">{{ restockError }}</p>

        <div class="dialog-actions">
          <button class="primary" :disabled="restockBusy" @click="submitRestock">
            {{ restockBusy ? 'Saving…' : 'Record Restock' }}
          </button>
        </div>
      </div>
    </div>

    <!-- ── EXPENSE TAB ── -->
    <div v-if="activeTab === 'expense'" class="panel">
      <div class="panel-title"><h2>Record Expense</h2></div>

      <div class="form-stack">
        <label>
          <span>Category</span>
          <input v-model="expenseCategory" type="text" list="expense-cats" placeholder="e.g. Ingredients" />
          <datalist id="expense-cats">
            <option v-for="cat in expenseCategories" :key="cat" :value="cat" />
          </datalist>
        </label>

        <label>
          <span>Amount (₱)</span>
          <input v-model="expenseAmount" type="text" inputmode="decimal" placeholder="0.00" />
        </label>

        <label>
          <span>Description</span>
          <input v-model="expenseDescription" type="text" placeholder="What was it for?" />
        </label>

        <label>
          <span>Delivery fee (₱)</span>
          <input v-model="expenseDeliveryFee" type="text" inputmode="decimal" placeholder="0.00" />
        </label>

        <label>
          <span>Date</span>
          <input v-model="expenseDate" type="datetime-local" />
        </label>

        <p v-if="expenseError" class="form-error">{{ expenseError }}</p>

        <div class="dialog-actions">
          <button class="primary" :disabled="expenseBusy" @click="submitExpense">
            {{ expenseBusy ? 'Saving…' : 'Record Expense' }}
          </button>
        </div>
      </div>
    </div>

    <!-- ── PRODUCTION TAB ── -->
    <div v-if="activeTab === 'produce'" class="panel">
      <div class="panel-title"><h2>Record Production</h2></div>

      <div class="form-stack">
        <label>
          <span>Product</span>
          <select v-model="prodProductId">
            <option value="" disabled>Select product</option>
            <option
              v-for="p in batchProducts"
              :key="p.id"
              :value="p.id"
            >{{ p.name }}</option>
          </select>
        </label>

        <div v-if="selectedProduct" class="callout info">
          <strong>Expected yield:</strong>
          {{ selectedProduct.expected_yield_quantity }} {{ selectedProduct.expected_yield_unit }}
        </div>

        <label>
          <span>Actual yield</span>
          <input v-model="prodActualYield" type="number" min="0" step="any" placeholder="0" />
        </label>

        <label>
          <span>Waste quantity</span>
          <input v-model="prodWaste" type="number" min="0" step="any" placeholder="0" />
        </label>

        <label>
          <span>Waste reason</span>
          <input v-model="prodWasteReason" type="text" placeholder="Optional" />
        </label>

        <p v-if="prodError" class="form-error">{{ prodError }}</p>

        <div class="dialog-actions">
          <button class="primary" :disabled="prodBusy" @click="submitProduction">
            {{ prodBusy ? 'Saving…' : 'Record Batch' }}
          </button>
        </div>
      </div>
    </div>

    <!-- ── ADJUSTMENT TAB ── -->
    <div v-if="activeTab === 'adjustment'" class="panel">
      <div class="panel-title"><h2>Adjust Inventory</h2></div>

      <div class="form-stack">
        <label>
          <span>Ingredient</span>
          <select v-model="adjIngredientId">
            <option value="" disabled>Select ingredient</option>
            <option v-for="ing in inventory?.ingredients ?? []" :key="ing.id" :value="ing.id">{{ ing.name }} ({{ ing.base_unit }})</option>
          </select>
        </label>
        <label>
          <span>Actual counted quantity</span>
          <input v-model="adjActualQuantity" type="number" min="0" step="any" placeholder="0" />
        </label>
        <label>
          <span>Reason</span>
          <input v-model="adjReason" type="text" placeholder="e.g. spoilage, damage, count correction" />
        </label>

        <p v-if="adjError" class="form-error">{{ adjError }}</p>

        <div class="dialog-actions">
          <button class="primary" :disabled="adjBusy" @click="submitAdjustment">
            {{ adjBusy ? 'Saving…' : 'Set Quantity' }}
          </button>
        </div>
      </div>
    </div>

    <!-- ── CASH TAB ── -->
    <div v-if="activeTab === 'cash'" class="panel">
      <div class="panel-title"><h2>Cash Shifts</h2></div>

      <!-- Cash overview -->
      <div class="metric-grid" style="margin-bottom:14px">
        <article class="metric-card accent">
          <span>{{ cashOverview.hasOpen ? 'Expected in drawer' : 'Last counted cash' }}</span>
          <strong>{{ formatPeso(cashOverview.hasOpen ? cashOverview.currentExpected : cashOverview.lastCounted) }}</strong>
          <small>{{ cashOverview.hasOpen ? 'Current open shift' : lastClosedShift ? 'From last closed shift' : 'No shifts yet' }}</small>
        </article>
        <article v-if="lastClosedShift && cashOverview.hasOpen" class="metric-card">
          <span>Last closed counted</span>
          <strong>{{ formatPeso(cashOverview.lastCounted) }}</strong>
          <small>{{ formatDateTime(lastClosedShift.closed_at!) }}</small>
        </article>
      </div>

      <!-- Open shift info -->
      <div v-if="openShiftData" class="callout info" style="margin-bottom: 16px;">
        <strong>Open shift</strong><br />
        Opened: {{ formatDateTime(openShiftData.opened_at) }}<br />
        Opening cash: {{ formatPeso(openShiftData.opening_cash_centavos) }}<br />
        Expected cash: {{ formatPeso(openShiftData.current_expected_cash_centavos) }}<br />
        Cash sales: {{ formatPeso(openShiftData.cash_sales_centavos) }}
      </div>

      <div class="form-stack">
        <!-- Open shift -->
        <template v-if="!openShiftData">
          <p class="eyebrow">Open a new shift</p>
          <label>
            <span>Opening cash (₱)</span>
            <input v-model="openShiftAmount" type="text" inputmode="decimal" placeholder="0.00" />
          </label>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button v-if="lastClosedShift" type="button" class="secondary small" @click="prefillFromLastShift">
              Use last counted ({{ formatPeso(lastClosedShift.counted_cash_centavos ?? 0) }})
            </button>
          </div>
          <div class="dialog-actions">
            <button class="primary" :disabled="cashBusy" @click="submitOpenShift">
              {{ cashBusy ? 'Opening…' : 'Open Shift' }}
            </button>
          </div>
        </template>

        <!-- Close shift -->
        <template v-if="openShiftData">
          <p class="eyebrow">Close current shift</p>
          <label>
            <span>Counted cash (₱)</span>
            <input v-model="closeShiftCounted" type="text" inputmode="decimal" placeholder="0.00" />
          </label>
          <label>
            <span>Note</span>
            <input v-model="closeShiftNote" type="text" placeholder="Optional note" />
          </label>
          <div class="dialog-actions">
            <button class="primary" :disabled="cashBusy" @click="submitCloseShift">
              {{ cashBusy ? 'Closing…' : 'Close Shift' }}
            </button>
          </div>
        </template>

        <p v-if="cashError" class="form-error">{{ cashError }}</p>

        <!-- Close result -->
        <div v-if="closeResult" class="callout" :class="closeResult.over_short_centavos === 0 ? 'info' : 'warning'">
          <strong>Shift closed</strong><br />
          Expected: {{ formatPeso(closeResult.expected_cash_centavos) }}<br />
          Counted: {{ formatPeso(closeResult.counted_cash_centavos) }}<br />
          Over/Short: {{ formatPeso(closeResult.over_short_centavos) }}
        </div>
      </div>
    </div>
  </div>
</template>
