<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import {
  closeShift,
  getCashRequests,
  getCashShifts,
  openShift,
  requestCashMovement,
  reviewCashMovement,
} from '../lib/api'
import { formatDateTime, formatTime } from '../lib/datetime'
import { formatPeso, formatPesoInput, parsePesoInput } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useUiStore } from '../stores/ui'
import type { CashMovementKind, CashRequest, CashShift } from '../lib/types'

const auth = useAuthStore()
const ui = useUiStore()

const shifts = ref<CashShift[]>([])
const requests = ref<CashRequest[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const showOpen = ref(false)
const openingCash = ref('0.00')
const showClose = ref(false)
const closingShift = ref<CashShift | null>(null)
const countedCash = ref('')
const closeNote = ref('')
const showRequest = ref(false)
const requestShiftId = ref('')
const requestKind = ref<CashMovementKind>('payout')
const requestAmount = ref('')
const requestReason = ref('')
const busy = ref(false)
const formError = ref<string | null>(null)

const openShifts = computed(() => shifts.value.filter((shift) => !shift.closed_at))
const myOpenShift = computed(() => openShifts.value.find((shift) => shift.cashier_id === auth.user?.id) ?? null)
const availableRequestShifts = computed(() =>
  auth.canManageBranch ? openShifts.value : openShifts.value.filter((shift) => shift.cashier_id === auth.user?.id),
)
const openExpected = computed(() => openShifts.value.reduce((sum, shift) => sum + shift.current_expected_cash_centavos, 0))
const openCashSales = computed(() => openShifts.value.reduce((sum, shift) => sum + shift.cash_sales_centavos, 0))
const pendingRequests = computed(() => requests.value.filter((request) => request.status === 'pending'))
const recentRequests = computed(() => requests.value.slice(0, 20))
const closedShifts = computed(() => shifts.value.filter((shift) => shift.closed_at))
const closedVariance = computed(() => closedShifts.value.reduce((sum, shift) => sum + (shift.over_short_centavos ?? 0), 0))

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    const [nextShifts, nextRequests] = await Promise.all([
      getCashShifts(auth.activeBranchId),
      getCashRequests(auth.activeBranchId),
    ])
    shifts.value = nextShifts
    requests.value = nextRequests
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
  } finally {
    loading.value = false
  }
}

function startOpen() {
  showOpen.value = true
  openingCash.value = '0.00'
  formError.value = null
}

async function submitOpen() {
  if (!auth.activeBranchId) return
  busy.value = true
  formError.value = null
  try {
    await openShift(auth.activeBranchId, parsePesoInput(openingCash.value))
    showOpen.value = false
    ui.success('Shift opened', 'Cash sales will now attach to your drawer.')
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function startClose(shift: CashShift) {
  closingShift.value = shift
  countedCash.value = formatPesoInput(shift.current_expected_cash_centavos)
  closeNote.value = ''
  formError.value = null
  showClose.value = true
}

async function submitClose() {
  if (!closingShift.value) return
  busy.value = true
  formError.value = null
  try {
    const result = await closeShift(closingShift.value.id, parsePesoInput(countedCash.value), closeNote.value)
    showClose.value = false
    const variance = result.over_short_centavos
    ui.notify(
      'Shift closed',
      variance === 0
        ? 'Cash counted exactly as expected.'
        : `${variance > 0 ? 'Over' : 'Short'} by ${formatPeso(Math.abs(variance))}.`,
      variance === 0 ? 'success' : 'warning',
    )
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function startRequest() {
  showRequest.value = true
  requestShiftId.value = myOpenShift.value?.id ?? availableRequestShifts.value[0]?.id ?? ''
  requestKind.value = 'payout'
  requestAmount.value = ''
  requestReason.value = ''
  formError.value = null
}

async function submitRequest() {
  busy.value = true
  formError.value = null
  try {
    await requestCashMovement({
      shiftId: requestShiftId.value,
      requestId: crypto.randomUUID(),
      kind: requestKind.value,
      amountCentavos: parsePesoInput(requestAmount.value),
      reason: requestReason.value,
    })
    showRequest.value = false
    ui.success('Cash request sent', 'An owner or manager must approve it before the drawer changes.')
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

async function decide(request: CashRequest, approve: boolean) {
  try {
    await reviewCashMovement(request.id, approve, '')
    ui.success(approve ? 'Cash request approved' : 'Cash request rejected')
    await load()
  } catch (reviewError) {
    ui.error('Could not review request', reviewError instanceof Error ? reviewError.message : String(reviewError))
  }
}

function shiftName(id: string) {
  const shift = shifts.value.find((item) => item.id === id)
  return shift ? `${shift.cashier_name ?? 'Team'} · ${formatTime(shift.opened_at)}` : 'Shift'
}

onMounted(() => void load())
watch(() => auth.activeBranchId, () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Cash drawer</h1>
        <p class="subtle">Shifts, payouts, safe drops, and the owner's approval trail.</p>
      </div>
      <div class="heading-actions">
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
        <button v-if="!myOpenShift" type="button" class="primary small" :disabled="!!myOpenShift" @click="startOpen">Open shift</button>
        <button v-else type="button" class="secondary small" @click="startClose(myOpenShift)">Close my shift</button>
      </div>
    </div>

    <div class="summary-strip">
      <article class="summary-card"><span>Expected cash open</span><strong>{{ formatPeso(openExpected) }}</strong></article>
      <article class="summary-card"><span>Cash sales in open shifts</span><strong>{{ formatPeso(openCashSales) }}</strong></article>
      <article class="summary-card" :class="{ attention: pendingRequests.length }"><span>Pending requests</span><strong>{{ pendingRequests.length }}</strong></article>
      <article class="summary-card"><span>Closed variance</span><strong>{{ formatPeso(closedVariance) }}</strong></article>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>

    <div class="cash-grid">
      <article class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">Current</p><h2>Open drawers</h2></div>
          <button type="button" class="text-link" :disabled="!availableRequestShifts.length" @click="startRequest">New cash request</button>
        </div>
        <div v-if="!openShifts.length" class="empty-panel">
          <h2>No open shift</h2>
          <p>Open a drawer before selling so cash can be reconciled.</p>
          <button type="button" class="primary" @click="startOpen">Open shift</button>
        </div>
        <div v-else class="open-shift-list">
          <div v-for="shift in openShifts" :key="shift.id" class="open-shift-card">
            <div>
              <p class="eyebrow">{{ shift.cashier_id === auth.user?.id ? 'Your drawer' : 'Team drawer' }}</p>
              <strong>{{ shift.cashier_name ?? 'Team member' }}</strong>
              <small>Opened {{ formatTime(shift.opened_at) }} with {{ formatPeso(shift.opening_cash_centavos) }}</small>
            </div>
            <div class="key-values compact">
              <div><span>Expected</span><b>{{ formatPeso(shift.current_expected_cash_centavos) }}</b></div>
              <div><span>Cash sales</span><b>{{ formatPeso(shift.cash_sales_centavos) }}</b></div>
            </div>
            <button
              v-if="shift.cashier_id === auth.user?.id || auth.canManageBranch"
              type="button"
              class="secondary small"
              @click="startClose(shift)"
            >
              Count &amp; close
            </button>
          </div>
        </div>
      </article>

      <article class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">Approvals</p><h2>Cash requests</h2></div>
          <span>{{ pendingRequests.length }}</span>
        </div>
        <div v-if="!recentRequests.length" class="empty-state">No cash requests yet.</div>
        <div v-else class="request-list">
          <div v-for="request in recentRequests" :key="request.id" class="request-item">
            <div>
              <strong>{{ request.kind === 'payout' ? 'Payout' : 'Safe drop' }} · {{ formatPeso(request.amount_centavos) }}</strong>
              <small>{{ request.reason }}</small>
              <small>{{ request.requested_by_name ?? 'Team' }} · {{ formatDateTime(request.created_at) }} · {{ shiftName(request.shift_id) }}</small>
            </div>
            <div class="request-actions">
              <span class="status-badge" :class="request.status">{{ request.status }}</span>
              <template v-if="request.status === 'pending' && auth.canManageBranch">
                <button type="button" class="mini-button approve" @click="decide(request, true)">Approve</button>
                <button type="button" class="mini-button reject" @click="decide(request, false)">Reject</button>
              </template>
            </div>
          </div>
        </div>
      </article>
    </div>

    <div class="panel table-panel">
      <div class="panel-title">
        <div><p class="eyebrow">Reconciliation</p><h2>Shift history</h2></div>
      </div>
      <div v-if="!closedShifts.length" class="empty-state">Closed shifts will appear here.</div>
      <div v-else class="data-table six-col">
        <div class="table-head"><span>Cashier</span><span>Opened</span><span>Closed</span><span>Expected</span><span>Counted</span><span>Variance</span></div>
        <div v-for="shift in closedShifts" :key="shift.id" class="table-row static">
          <span><b>{{ shift.cashier_name ?? 'Team' }}</b><small>{{ formatPeso(shift.opening_cash_centavos) }} opening</small></span>
          <span>{{ formatDateTime(shift.opened_at) }}</span>
          <span>{{ shift.closed_at ? formatDateTime(shift.closed_at) : '—' }}</span>
          <span>{{ formatPeso(shift.expected_cash_centavos ?? 0) }}</span>
          <span>{{ formatPeso(shift.counted_cash_centavos ?? 0) }}</span>
          <span :class="(shift.over_short_centavos ?? 0) < 0 ? 'negative-text' : 'positive-text'">
            {{ formatPeso(shift.over_short_centavos ?? 0) }}
          </span>
        </div>
      </div>
    </div>

    <AppModal v-if="showOpen" title="Open a cash shift" subtitle="Count the starting drawer and record it." @close="showOpen = false">
      <form class="form-stack" @submit.prevent="submitOpen">
        <label><span>Opening cash (₱)</span><input v-model="openingCash" inputmode="decimal" placeholder="0.00" autofocus required /></label>
        <p class="form-note">This is the cash physically in the drawer before the first sale.</p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showOpen = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Opening…' : 'Open shift' }}</button>
        </div>
      </form>
    </AppModal>

    <AppModal v-if="showClose && closingShift" title="Count and close shift" :subtitle="`${closingShift.cashier_name ?? 'Team'} · expected ${formatPeso(closingShift.current_expected_cash_centavos)}`" @close="showClose = false">
      <form class="form-stack" @submit.prevent="submitClose">
        <label><span>Counted cash (₱)</span><input v-model="countedCash" inputmode="decimal" placeholder="0.00" autofocus required /></label>
        <label><span>Note</span><textarea v-model="closeNote" rows="2" maxlength="300" placeholder="Optional note about the drawer" /></label>
        <p class="form-note">Expected includes opening cash plus net cash sales and approved cash movements.</p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showClose = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Closing…' : 'Close shift' }}</button>
        </div>
      </form>
    </AppModal>

    <AppModal v-if="showRequest" title="Request a cash movement" subtitle="An owner must approve before cash leaves the drawer." @close="showRequest = false">
      <form class="form-stack" @submit.prevent="submitRequest">
        <label>
          <span>Drawer</span>
          <select v-model="requestShiftId" required>
            <option v-for="shift in availableRequestShifts" :key="shift.id" :value="shift.id">
              {{ shift.cashier_name ?? 'Team' }} · opened {{ formatTime(shift.opened_at) }}
            </option>
          </select>
        </label>
        <label>
          <span>Movement</span>
          <select v-model="requestKind">
            <option value="payout">Payout / expense</option>
            <option value="safe_drop">Safe drop</option>
          </select>
        </label>
        <label><span>Amount (₱)</span><input v-model="requestAmount" inputmode="decimal" placeholder="0.00" required /></label>
        <label><span>Reason</span><textarea v-model="requestReason" rows="2" maxlength="200" minlength="3" required placeholder="What is this for?" /></label>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showRequest = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Sending…' : 'Send request' }}</button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
