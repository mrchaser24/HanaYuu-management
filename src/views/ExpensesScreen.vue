<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import { getCashShifts, getExpenses, recordExpense } from '../lib/api'
import { daysAgoManila, formatDate, formatDateTime, manilaDate } from '../lib/datetime'
import { formatPeso, parsePesoInput } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useUiStore } from '../stores/ui'
import type { Expense } from '../lib/types'

const auth = useAuthStore()
const ui = useUiStore()

const expenses = ref<Expense[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const from = ref(daysAgoManila(29))
const to = ref(manilaDate())
const showForm = ref(false)
const category = ref('Ingredients')
const description = ref('')
const amount = ref('')
const deliveryFee = ref('0')
const paidFromCash = ref(false)
const shiftId = ref<string | null>(null)
const spentAt = ref('')
const busy = ref(false)
const formError = ref<string | null>(null)

const total = computed(() => expenses.value.reduce((sum, expense) => sum + expense.amount_centavos, 0))
const cashPaid = computed(() =>
  expenses.value.filter((expense) => expense.paid_from_cash).reduce((sum, expense) => sum + expense.amount_centavos, 0),
)
const categories = computed(() => [...new Set(expenses.value.map((expense) => expense.category))].sort())

const openShifts = ref<{ id: string; cashier_id: string; opening_cash_centavos: number }[]>([])
const myOpenShift = computed(() => openShifts.value.find((s) => s.cashier_id === auth.user?.id) ?? null)

function localDateTimeInput(date: Date) {
  const offset = date.getTimezoneOffset()
  return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 16)
}

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    const [exps, shifts] = await Promise.all([
      getExpenses(auth.activeBranchId, from.value, to.value),
      getCashShifts(auth.activeBranchId),
    ])
    expenses.value = exps
    openShifts.value = shifts.map((s) => ({
      id: s.id,
      cashier_id: s.cashier_id,
      opening_cash_centavos: s.opening_cash_centavos,
    }))
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
    expenses.value = []
  } finally {
    loading.value = false
  }
}

function openForm() {
  showForm.value = true
  category.value = 'Ingredients'
  description.value = ''
  amount.value = ''
  deliveryFee.value = '0'
  paidFromCash.value = false
  shiftId.value = myOpenShift.value?.id ?? null
  spentAt.value = localDateTimeInput(new Date())
  formError.value = null
}

async function submit() {
  if (!auth.activeBranchId) return
  formError.value = null
  if (paidFromCash.value && !shiftId.value) {
    formError.value = 'No open shift found for this branch. Open a cash drawer first.'
    return
  }
  busy.value = true
  try {
    await recordExpense({
      branchId: auth.activeBranchId,
      category: category.value,
      description: description.value,
      amountCentavos: parsePesoInput(amount.value),
      paidFromCash: paidFromCash.value,
      cashMovementId: null,
      spentAt: new Date(spentAt.value).toISOString(),
      deliveryFee: parsePesoInput(deliveryFee.value),
      shiftId: paidFromCash.value ? shiftId.value : undefined,
    })
    showForm.value = false
    ui.success('Expense recorded', 'Profit and reports will include it immediately.')
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

onMounted(() => void load())
watch([from, to, () => auth.activeBranchId], () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Expenses</h1>
        <p class="subtle">Track spending separately from stock and cash movements.</p>
      </div>
      <div class="heading-actions">
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
        <button type="button" class="primary small" @click="openForm">Record expense</button>
      </div>
    </div>

    <div class="panel filter-bar">
      <label><span>From</span><input v-model="from" type="date" /></label>
      <label><span>To</span><input v-model="to" type="date" /></label>
      <div class="filter-summary"><span>Total</span><strong>{{ formatPeso(total) }}</strong></div>
    </div>

    <div class="summary-strip">
      <article class="summary-card"><span>Expenses shown</span><strong>{{ formatPeso(total) }}</strong></article>
      <article class="summary-card"><span>Entries</span><strong>{{ expenses.length }}</strong></article>
      <article class="summary-card"><span>Paid from drawer</span><strong>{{ formatPeso(cashPaid) }}</strong></article>
      <article class="summary-card"><span>Categories</span><strong>{{ categories.length }}</strong></article>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>
    <div v-if="loading && !expenses.length" class="panel loading-panel">Loading expenses…</div>
    <div v-else-if="!expenses.length" class="panel empty-panel">
      <h2>No expenses in this period</h2>
      <p>Record rent, utilities, supplies, or other spending.</p>
      <button type="button" class="primary" @click="openForm">Record expense</button>
    </div>
    <div v-else class="panel table-panel">
        <div class="data-table six-col">
          <div class="table-head"><span>Date</span><span>Category</span><span>Description</span><span>Paid from</span><span>Amount</span><span>Delivery fee</span><span>Recorded by</span></div>
          <div v-for="expense in expenses" :key="expense.id" class="table-row static">
            <span>{{ formatDate(expense.spent_at) }}<small>{{ formatDateTime(expense.spent_at).split(', ').at(-1) }}</small></span>
            <span><span class="status-badge neutral">{{ expense.category }}</span></span>
            <span>{{ expense.description }}</span>
            <span>{{ expense.paid_from_cash ? 'Cash drawer' : 'Other' }}</span>
            <span class="amount">{{ formatPeso(expense.amount_centavos) }}</span>
            <span class="amount">{{ formatPeso(expense.delivery_fee_centavos ?? 0) }}</span>
            <span>{{ expense.created_by_name ?? '—' }}</span>
          </div>
        </div>
    </div>

    <AppModal v-if="showForm" title="Record an expense" subtitle="Expenses reduce net profit but do not move stock." @close="showForm = false">
      <form class="form-stack" @submit.prevent="submit">
        <div class="two-column">
          <label>
            <span>Category</span>
            <input v-model="category" list="expense-categories" maxlength="60" required />
            <datalist id="expense-categories">
              <option value="Ingredients" /><option value="Utilities" /><option value="Rent" />
              <option value="Salary" /><option value="Transport" /><option value="Supplies" /><option value="Other" />
            </datalist>
          </label>
          <label><span>Amount (₱)</span><input v-model="amount" inputmode="decimal" placeholder="0.00" required /></label>
          <label>
            <span>Delivery fee (₱)</span>
            <input v-model="deliveryFee" inputmode="decimal" placeholder="0.00" />
          </label>
        </div>
        <label><span>Description</span><input v-model="description" maxlength="200" minlength="3" required placeholder="What was purchased?" /></label>
        <div class="two-column">
          <label><span>Date and time</span><input v-model="spentAt" type="datetime-local" required /></label>
          <label class="check-field">
            <input v-model="paidFromCash" type="checkbox" />
            <span>Paid from cash drawer</span>
          </label>
        </div>
        <div v-if="paidFromCash" class="two-column">
          <label>
            <span>Shift</span>
            <select v-model="shiftId" :disabled="!myOpenShift">
              <option v-for="s in openShifts" :key="s.id" :value="s.id">{{ s.cashier_id === auth.user?.id ? 'Your drawer' : 'Team drawer' }} (opened {{ formatPeso(s.opening_cash_centavos) }})</option>
            </select>
          </label>
          <span v-if="!myOpenShift" class="form-note">No open shift. Open a drawer in Cash drawer first.</span>
        </div>
        <p class="form-note">When paid from the cash drawer, the amount plus delivery fee is deducted immediately from the open shift.</p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showForm = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Saving…' : 'Record expense' }}</button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
