<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore } from '../stores/catalog'
import { useUiStore } from '../stores/ui'
import { formatPeso, parsePesoInput } from '../lib/money'
import { formatDateTime } from '../lib/datetime'
import {
  recordRestock,
  recordExpense,
  postProductionBatch,
  openShift,
  closeShift,
  getCashShifts,
  getInventory,
} from '../lib/api'
import type { CashShift, InventoryResponse } from '../lib/types'

const auth = useAuthStore()
const catalog = useCatalogStore()
const ui = useUiStore()

// ── Tabs ──

type Tab = 'restock' | 'expense' | 'produce' | 'cash'
const activeTab = ref<Tab>('restock')

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
  unitCost: string
}

const restockLines = ref<RestockLine[]>([{ ingredientId: '', quantity: '', unitCost: '' }])
const restockSupplier = ref('')
const restockNote = ref('')
const restockDeliveryFee = ref('')
const restockDate = ref(localDateTimeInput(new Date()))
const restockBusy = ref(false)
const restockError = ref('')

function addRestockLine() {
  restockLines.value.push({ ingredientId: '', quantity: '', unitCost: '' })
}

function removeRestockLine(index: number) {
  if (restockLines.value.length > 1) restockLines.value.splice(index, 1)
}

async function submitRestock() {
  restockError.value = ''
  const branchId = auth.activeBranchId
  if (!branchId) { restockError.value = 'No active branch'; return }

  const items = restockLines.value.map((l) => ({
    ingredient_id: l.ingredientId,
    quantity: Number(l.quantity) || 0,
    unit_cost_centavos: parsePesoInput(l.unitCost),
  }))

  if (items.some((i) => !i.ingredient_id || i.quantity <= 0 || i.unit_cost_centavos <= 0)) {
    restockError.value = 'Fill in all line items (ingredient, quantity > 0, cost > 0).'
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
    })
    ui.success('Restock recorded')
    restockLines.value = [{ ingredientId: '', quantity: '', unitCost: '' }]
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
      paidFromCash: false,
      cashMovementId: null,
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
      <button :class="{ active: activeTab === 'restock' }" @click="activeTab = 'restock'">Restock</button>
      <button :class="{ active: activeTab === 'expense' }" @click="activeTab = 'expense'">Expense</button>
      <button :class="{ active: activeTab === 'produce' }" @click="activeTab = 'produce'">Produce</button>
      <button :class="{ active: activeTab === 'cash' }" @click="activeTab = 'cash'">Cash</button>
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
            <span>Cost per unit (₱)</span>
            <input v-model="line.unitCost" type="text" inputmode="decimal" placeholder="0.00" />
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

    <!-- ── CASH TAB ── -->
    <div v-if="activeTab === 'cash'" class="panel">
      <div class="panel-title"><h2>Cash Shifts</h2></div>

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
