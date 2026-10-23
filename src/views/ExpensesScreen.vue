<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import { getExpenses, recordExpense } from '../lib/api'
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
const paidFromCash = ref(false)
const spentAt = ref('')
const busy = ref(false)
const formError = ref<string | null>(null)

const total = computed(() => expenses.value.reduce((sum, expense) => sum + expense.amount_centavos, 0))
const cashPaid = computed(() =>
  expenses.value.filter((expense) => expense.paid_from_cash).reduce((sum, expense) => sum + expense.amount_centavos, 0),
)
const categories = computed(() => [...new Set(expenses.value.map((expense) => expense.category))].sort())

function localDateTimeInput(date: Date) {
  const offset = date.getTimezoneOffset()
  return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 16)
}

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    expenses.value = await getExpenses(auth.activeBranchId, from.value, to.value)
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
  } finally {
    loading.value = false
  }
}

function openForm() {
  showForm.value = true
  category.value = 'Ingredients'
  description.value = ''
  amount.value = ''
  paidFromCash.value = false
  spentAt.value = localDateTimeInput(new Date())
  formError.value = null
}

async function submit() {
  if (!auth.activeBranchId) return
  busy.value = true
  formError.value = null
  try {
    await recordExpense({
      branchId: auth.activeBranchId,
      category: category.value,
      description: description.value,
      amountCentavos: parsePesoInput(amount.value),
      paidFromCash: paidFromCash.value,
      cashMovementId: null,
      spentAt: new Date(spentAt.value).toISOString(),
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
        <div class="table-head"><span>Date</span><span>Category</span><span>Description</span><span>Paid from</span><span>Amount</span><span>Recorded by</span></div>
        <div v-for="expense in expenses" :key="expense.id" class="table-row static">
          <span>{{ formatDate(expense.spent_at) }}<small>{{ formatDateTime(expense.spent_at).split(', ').at(-1) }}</small></span>
          <span><span class="status-badge neutral">{{ expense.category }}</span></span>
          <span>{{ expense.description }}</span>
          <span>{{ expense.paid_from_cash ? 'Cash drawer' : 'Other' }}</span>
          <span class="amount">{{ formatPeso(expense.amount_centavos) }}</span>
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
        </div>
        <label><span>Description</span><input v-model="description" maxlength="200" minlength="3" required placeholder="What was purchased?" /></label>
        <div class="two-column">
          <label><span>Date and time</span><input v-model="spentAt" type="datetime-local" required /></label>
          <label class="check-field">
            <input v-model="paidFromCash" type="checkbox" />
            <span>Paid from cash drawer</span>
          </label>
        </div>
        <p class="form-note">For drawer cash, request a payout in Cash drawer so the expected cash stays accurate.</p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showForm = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Saving…' : 'Record expense' }}</button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
