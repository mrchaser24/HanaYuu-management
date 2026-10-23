<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import AppModal from '../components/AppModal.vue'
import { requestCorrection, reviewCorrection } from '../lib/api'
import { formatDateTime } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useSalesStore } from '../stores/sales'
import { useUiStore } from '../stores/ui'
import type { CorrectionKind, PaymentKind } from '../lib/types'

const route = useRoute()
const auth = useAuthStore()
const sales = useSalesStore()
const ui = useUiStore()

const showCorrection = ref(false)
const correctionKind = ref<CorrectionKind>('refund')
const correctionReason = ref('')
const showReview = ref(false)
const reviewAction = ref<'approve' | 'void' | 'reject'>('approve')
const reviewReason = ref('')
const showApproval = ref(false)
const refundMethod = ref<PaymentKind>('cash')
const refundReference = ref('')
const approvalNote = ref('')
const busy = ref(false)
const actionError = ref<string | null>(null)

const orderId = computed(() => String(route.params.id))
const detail = computed(() => sales.orderDetail)
const order = computed(() => detail.value?.order ?? null)
const pendingCorrection = computed(() => detail.value?.corrections.find((correction) => correction.status === 'pending') ?? null)
const canRequestCorrection = computed(
  () =>
    order.value?.status === 'completed' &&
    !detail.value?.reversal &&
    !pendingCorrection.value &&
    Boolean(auth.activeBranchId),
)
const canReviewOrder = computed(() => order.value?.status === 'needs_review' && auth.canManageBranch)
const totalCost = computed(() =>
  (detail.value?.lines ?? []).reduce((sum, line) => sum + line.cost_snapshot_centavos, 0),
)
const estimated = computed(() => (detail.value?.lines ?? []).some((line) => line.cost_estimated))

async function load() {
  try {
    await sales.loadOrder(orderId.value)
  } catch {
    return
  }
  const payment = sales.orderDetail?.payment
  if (payment) refundMethod.value = payment.method
}

async function submitCorrection() {
  busy.value = true
  actionError.value = null
  try {
    await requestCorrection(orderId.value, correctionKind.value, correctionReason.value)
    showCorrection.value = false
    correctionReason.value = ''
    await load()
    ui.success('Correction requested', 'An owner or manager will review it.')
  } catch (error) {
    actionError.value = error instanceof Error ? error.message : String(error)
  } finally {
    busy.value = false
  }
}

async function submitReview() {
  busy.value = true
  actionError.value = null
  try {
    await sales.reviewOrder(orderId.value, reviewAction.value, reviewReason.value)
    showReview.value = false
    reviewReason.value = ''
    ui.success(
      reviewAction.value === 'approve' ? 'Offline order approved' : 'Offline order closed',
      reviewAction.value === 'approve' ? 'Stock and sales have been posted.' : 'The order was not counted as a sale.',
    )
  } catch (error) {
    actionError.value = error instanceof Error ? error.message : String(error)
  } finally {
    busy.value = false
  }
}

async function submitApproval() {
  if (!pendingCorrection.value) return
  busy.value = true
  actionError.value = null
  try {
    await reviewCorrection({
      correctionId: pendingCorrection.value.id,
      approve: true,
      note: approvalNote.value,
      refundMethod: refundMethod.value,
      refundReference: refundReference.value,
    })
    showApproval.value = false
    approvalNote.value = ''
    await load()
    ui.success('Correction approved', 'Stock and refund records are updated.')
  } catch (error) {
    actionError.value = error instanceof Error ? error.message : String(error)
  } finally {
    busy.value = false
  }
}

onMounted(() => void load())
watch(() => route.params.id, () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <RouterLink :to="{ name: 'sales' }" class="back-link">← Back to sales</RouterLink>
        <h1>Order detail</h1>
        <p v-if="order" class="subtle">{{ formatDateTime(order.created_at) }} · {{ order.cashier_name ?? 'Team member' }}</p>
      </div>
      <div v-if="order" class="heading-actions">
        <button v-if="canReviewOrder" type="button" class="primary small" @click="showReview = true">Review offline order</button>
        <button v-if="canRequestCorrection" type="button" class="secondary small" @click="showCorrection = true">Request correction</button>
        <button v-if="pendingCorrection && auth.canManageBranch" type="button" class="primary small" @click="showApproval = true">
          Review correction
        </button>
      </div>
    </div>

    <div v-if="sales.loadingOrder && !order" class="panel loading-panel">Loading order…</div>
    <div v-else-if="!order" class="panel empty-panel"><h2>Order not found</h2><p>{{ sales.error }}</p></div>
    <template v-else>
      <div v-if="order.status === 'needs_review'" class="callout warning">
        <strong>This offline order needs an owner decision.</strong>
        {{ order.review_reason || 'The sale conflicted with current prices or stock.' }} Approving will re-check stock and post the sale.
      </div>
      <div v-if="estimated" class="callout warning">
        This order includes estimated costs because a recipe is incomplete. Profit figures are not final.
      </div>

      <div class="order-grid">
        <article class="panel order-main">
          <div class="panel-title">
            <div><p class="eyebrow">Order</p><h2 class="mono">#{{ order.id.slice(0, 8).toUpperCase() }}</h2></div>
            <span class="status-badge" :class="order.status">{{ order.status.replace('_', ' ') }}</span>
          </div>
          <div class="order-lines">
            <div v-for="line in detail?.lines ?? []" :key="line.id" class="order-line">
              <div class="order-line-head">
                <div>
                  <strong>{{ line.quantity }} × {{ line.product_name }}</strong>
                  <small>{{ line.options.map((option) => option.name).join(' · ') || 'No options' }}</small>
                </div>
                <b>{{ formatPeso(line.line_subtotal_centavos) }}</b>
              </div>
              <div class="order-line-meta">
                <span>{{ formatPeso(line.unit_price_centavos) }} each</span>
                <span>{{ line.stock_model === 'batch_produced' ? 'Batch produced' : 'Made to order' }}</span>
                <span :class="{ estimate: line.cost_estimated }">Cost {{ formatPeso(line.cost_snapshot_centavos) }}</span>
              </div>
            </div>
          </div>

          <div class="totals-block">
            <div><span>Subtotal</span><b>{{ formatPeso(order.subtotal_centavos) }}</b></div>
            <div v-if="order.discount_centavos"><span>Discount · {{ order.discount_reason }}</span><b>−{{ formatPeso(order.discount_centavos) }}</b></div>
            <div v-if="order.tax_inclusive && order.tax_centavos">
              <span>VAT included ({{ (order.tax_rate_bps / 100).toFixed(2).replace('.00', '') }}%)</span>
              <b>{{ formatPeso(order.tax_centavos) }}</b>
            </div>
            <div class="grand-total"><span>Total</span><b>{{ formatPeso(order.total_centavos) }}</b></div>
          </div>
        </article>

        <aside class="order-side">
          <article class="panel">
            <div class="panel-title"><div><p class="eyebrow">Payment</p><h2>{{ order.payment_method_name ?? 'Not recorded' }}</h2></div></div>
            <div class="key-values">
              <div><span>Method</span><b>{{ detail?.payment?.method ?? '—' }}</b></div>
              <div v-if="detail?.payment?.reference"><span>Reference</span><b>{{ detail.payment.reference }}</b></div>
              <div v-if="order.tendered_centavos !== null"><span>Tendered</span><b>{{ formatPeso(order.tendered_centavos) }}</b></div>
              <div v-if="order.change_centavos !== null"><span>Change</span><b>{{ formatPeso(order.change_centavos) }}</b></div>
              <div><span>Recorded cost</span><b>{{ formatPeso(totalCost) }}</b></div>
            </div>
          </article>

          <article v-if="detail?.reversal" class="panel">
            <div class="panel-title"><div><p class="eyebrow">Reversed</p><h2>Refund posted</h2></div></div>
            <div class="key-values">
              <div><span>Amount</span><b>{{ formatPeso(detail.reversal.total_centavos) }}</b></div>
              <div><span>Method</span><b>{{ detail.reversal.refund_method }}</b></div>
              <div v-if="detail.reversal.refund_reference"><span>Reference</span><b>{{ detail.reversal.refund_reference }}</b></div>
              <div><span>When</span><b>{{ formatDateTime(detail.reversal.created_at) }}</b></div>
            </div>
          </article>

          <article class="panel">
            <div class="panel-title"><div><p class="eyebrow">Audit trail</p><h2>Corrections</h2></div></div>
            <div v-if="detail?.corrections.length" class="timeline">
              <div v-for="correction in detail.corrections" :key="correction.id" class="timeline-item">
                <span class="status-badge" :class="correction.status">{{ correction.status }}</span>
                <strong>{{ correction.kind === 'void' ? 'Void request' : 'Refund request' }}</strong>
                <p>{{ correction.reason }}</p>
                <small>{{ formatDateTime(correction.created_at) }}</small>
                <p v-if="correction.review_note" class="review-note">Note: {{ correction.review_note }}</p>
              </div>
            </div>
            <p v-else class="empty-state">No corrections requested.</p>
          </article>
        </aside>
      </div>
    </template>

    <AppModal v-if="showCorrection" title="Request a correction" subtitle="An owner must approve any void or refund." @close="showCorrection = false">
      <form class="form-stack" @submit.prevent="submitCorrection">
        <label>
          <span>Correction type</span>
          <select v-model="correctionKind">
            <option value="refund">Refund the order</option>
            <option value="void">Void the order</option>
          </select>
        </label>
        <label>
          <span>Reason</span>
          <textarea v-model="correctionReason" rows="3" minlength="3" maxlength="300" required placeholder="What happened?" />
        </label>
        <p v-if="actionError" class="form-error">{{ actionError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showCorrection = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy || correctionReason.trim().length < 3">
            {{ busy ? 'Sending…' : 'Send request' }}
          </button>
        </div>
      </form>
    </AppModal>

    <AppModal v-if="showReview" title="Review offline order" subtitle="Approve only after stock is available." @close="showReview = false">
      <form class="form-stack" @submit.prevent="submitReview">
        <label>
          <span>Decision</span>
          <select v-model="reviewAction">
            <option value="approve">Approve and post sale</option>
            <option value="void">Void the order</option>
            <option value="reject">Reject the order</option>
          </select>
        </label>
        <label>
          <span>Review note</span>
          <textarea v-model="reviewReason" rows="3" maxlength="300" placeholder="Optional note for the audit trail" />
        </label>
        <div v-if="order?.review_reason" class="callout warning">{{ order.review_reason }}</div>
        <p v-if="actionError" class="form-error">{{ actionError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showReview = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Posting…' : 'Confirm decision' }}</button>
        </div>
      </form>
    </AppModal>

    <AppModal v-if="showApproval" title="Approve correction" subtitle="Stock returns and a refund record will be posted." @close="showApproval = false">
      <form class="form-stack" @submit.prevent="submitApproval">
        <div class="callout warning">
          {{ pendingCorrection?.kind === 'void' ? 'Void' : 'Refund' }} of {{ formatPeso(order?.total_centavos ?? 0) }}.
          {{ pendingCorrection?.reason }}
        </div>
        <label>
          <span>Refund method</span>
          <select v-model="refundMethod">
            <option value="cash">Cash</option>
            <option value="gcash">GCash</option>
          </select>
        </label>
        <label>
          <span>Reference</span>
          <input v-model="refundReference" maxlength="80" placeholder="Optional refund reference" />
        </label>
        <label>
          <span>Approval note</span>
          <textarea v-model="approvalNote" rows="2" maxlength="300" placeholder="Optional note" />
        </label>
        <p v-if="actionError" class="form-error">{{ actionError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showApproval = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Posting…' : 'Approve and refund' }}</button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
