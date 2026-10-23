<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import { getCorrections, reviewCorrection } from '../lib/api'
import { formatDateTime } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useUiStore } from '../stores/ui'
import type { Correction, PaymentKind } from '../lib/types'

const auth = useAuthStore()
const ui = useUiStore()

const corrections = ref<Correction[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const filter = ref<'pending' | 'all'>('pending')
const selected = ref<Correction | null>(null)
const decision = ref<'approve' | 'reject'>('approve')
const note = ref('')
const refundMethod = ref<PaymentKind>('cash')
const refundReference = ref('')
const busy = ref(false)
const formError = ref<string | null>(null)

const filtered = computed(() =>
  corrections.value.filter((correction) => filter.value === 'all' || correction.status === 'pending'),
)
const pendingCount = computed(() => corrections.value.filter((correction) => correction.status === 'pending').length)

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    corrections.value = await getCorrections(auth.activeBranchId)
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
  } finally {
    loading.value = false
  }
}

function openReview(correction: Correction, nextDecision: 'approve' | 'reject') {
  selected.value = correction
  decision.value = nextDecision
  note.value = ''
  refundMethod.value = correction.refund_method ?? 'cash'
  refundReference.value = ''
  formError.value = null
}

async function submit() {
  if (!selected.value) return
  busy.value = true
  formError.value = null
  try {
    await reviewCorrection({
      correctionId: selected.value.id,
      approve: decision.value === 'approve',
      note: note.value,
      refundMethod: decision.value === 'approve' ? refundMethod.value : null,
      refundReference: decision.value === 'approve' ? refundReference.value : null,
    })
    selected.value = null
    ui.success(decision.value === 'approve' ? 'Correction approved' : 'Correction rejected')
    await load()
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

onMounted(() => void load())
watch(() => auth.activeBranchId, () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Corrections</h1>
        <p class="subtle">Approve voids and refunds with the original payment method and a full audit trail.</p>
      </div>
      <button type="button" class="secondary small" :disabled="loading" @click="load">
        {{ loading ? 'Refreshing…' : 'Refresh' }}
      </button>
    </div>

    <div class="summary-strip">
      <article class="summary-card" :class="{ attention: pendingCount }"><span>Pending decisions</span><strong>{{ pendingCount }}</strong></article>
      <article class="summary-card"><span>All corrections</span><strong>{{ corrections.length }}</strong></article>
      <article class="summary-card"><span>Approved refunds</span><strong>{{ formatPeso(corrections.filter((item) => item.status === 'approved').reduce((sum, item) => sum + (item.refund_amount_centavos ?? 0), 0)) }}</strong></article>
    </div>

    <div class="tabs">
      <button type="button" :class="{ active: filter === 'pending' }" @click="filter = 'pending'">Needs review</button>
      <button type="button" :class="{ active: filter === 'all' }" @click="filter = 'all'">All corrections</button>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>
    <div v-if="loading && !corrections.length" class="panel loading-panel">Loading corrections…</div>
    <div v-else-if="!filtered.length" class="panel empty-panel">
      <h2>{{ filter === 'pending' ? 'Nothing waiting' : 'No corrections' }}</h2>
      <p>{{ filter === 'pending' ? 'Every correction has been reviewed.' : 'Staff can request a correction from an order detail.' }}</p>
      <RouterLink :to="{ name: 'sales' }" class="secondary">Browse sales</RouterLink>
    </div>
    <div v-else class="panel correction-list">
      <article v-for="correction in filtered" :key="correction.id" class="correction-item">
        <div class="correction-main">
          <div>
            <span class="status-badge" :class="correction.status">{{ correction.status }}</span>
            <strong>{{ correction.kind === 'void' ? 'Void request' : 'Refund request' }} · {{ formatPeso(correction.order_total_centavos) }}</strong>
          </div>
          <p>{{ correction.reason }}</p>
          <small>
            {{ correction.requested_by_name ?? 'Team' }} · {{ formatDateTime(correction.created_at) }} ·
            <RouterLink :to="{ name: 'order', params: { id: correction.order_id } }" class="text-link">
              Order #{{ correction.order_id.slice(0, 8).toUpperCase() }}
            </RouterLink>
          </small>
          <small v-if="correction.review_note">Review note: {{ correction.review_note }}</small>
          <small v-if="correction.status === 'approved'">
            Refunded via {{ correction.refund_method ?? 'original method' }}
            <template v-if="correction.refund_reference"> · {{ correction.refund_reference }}</template>
          </small>
        </div>
        <div v-if="correction.status === 'pending'" class="correction-actions">
          <button type="button" class="primary small" @click="openReview(correction, 'approve')">Approve</button>
          <button type="button" class="secondary small" @click="openReview(correction, 'reject')">Reject</button>
        </div>
      </article>
    </div>

    <AppModal
      v-if="selected"
      :title="decision === 'approve' ? 'Approve correction' : 'Reject correction'"
      :subtitle="`${selected.kind === 'void' ? 'Void' : 'Refund'} · ${formatPeso(selected.order_total_centavos)}`"
      @close="selected = null"
    >
      <form class="form-stack" @submit.prevent="submit">
        <div class="callout warning" :class="{ danger: decision === 'reject' }">
          <strong>{{ selected.reason }}</strong>
        </div>
        <p v-if="decision === 'approve'" class="form-note">
          Approving returns consumed stock and creates a refund record. The order status will become
          {{ selected.kind === 'void' ? 'voided' : 'refunded' }}.
        </p>
        <template v-if="decision === 'approve'">
          <div class="two-column">
            <label>
              <span>Refund method</span>
              <select v-model="refundMethod">
                <option value="cash">Cash</option>
                <option value="gcash">GCash</option>
              </select>
            </label>
            <label><span>Reference</span><input v-model="refundReference" maxlength="80" placeholder="Optional reference" /></label>
          </div>
        </template>
        <label>
          <span>{{ decision === 'approve' ? 'Approval note' : 'Rejection reason' }}</span>
          <textarea v-model="note" rows="2" maxlength="300" :required="decision === 'reject'" placeholder="Optional note for the audit trail" />
        </label>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="selected = null">Cancel</button>
          <button type="submit" class="primary" :class="{ destructive: decision === 'reject' }" :disabled="busy">
            {{ busy ? 'Posting…' : decision === 'approve' ? 'Approve and post' : 'Reject request' }}
          </button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
