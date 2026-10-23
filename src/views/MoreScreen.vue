<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import AppModal from '../components/AppModal.vue'
import VaultDialog from '../components/VaultDialog.vue'
import { formatDateTime, manilaDate } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useOfflineStore } from '../stores/offline'
import { useUiStore } from '../stores/ui'
import type { OfflineCheckout } from '../lib/types'

const auth = useAuthStore()
const offline = useOfflineStore()
const ui = useUiStore()
const router = useRouter()

const showVault = ref(false)
const showChangePin = ref(false)
const pending = ref<OfflineCheckout[]>([])
const loadingPending = ref(false)
const currentPin = ref('')
const nextPin = ref('')
const confirmPin = ref('')
const pinError = ref<string | null>(null)
const busy = ref(false)
const persisted = ref<boolean | null>(null)
const registering = ref(false)

const pendingTotal = computed(() => pending.value.reduce((sum, record) => sum + record.total_centavos, 0))
const connectionLabel = computed(() => (ui.online ? 'Online' : 'Offline'))
const storageLabel = computed(() => {
  if (persisted.value === null) return 'Not checked'
  return persisted.value ? 'Protected from automatic cleanup' : 'Browser may clear storage under pressure'
})

async function loadPending() {
  if (!offline.unlocked) {
    pending.value = []
    return
  }
  loadingPending.value = true
  try {
    pending.value = await offline.listPending()
  } catch {
    pending.value = []
  } finally {
    loadingPending.value = false
  }
}

async function syncNow() {
  try {
    const result = await offline.syncPending()
    await loadPending()
    if (result.accepted) ui.success(`${result.accepted} sale${result.accepted === 1 ? '' : 's'} synced`)
    if (result.needsReview) {
      ui.notify(
        `${result.needsReview} sale${result.needsReview === 1 ? '' : 's'} saved for review`,
        'Stock was not deducted. Review the order in Sales.',
        'warning',
      )
    }
    if (offline.lastSyncError) ui.error('Could not sync', offline.lastSyncError)
    else if (!result.accepted && !result.needsReview) ui.notify('Nothing to sync')
  } catch (error) {
    ui.error('Sync unavailable', error instanceof Error ? error.message : String(error))
  }
}

async function onVaultReady() {
  showVault.value = false
  await loadPending()
  ui.success(offline.vaultExists ? 'Vault unlocked' : 'PIN created', 'Offline sales are encrypted on this device.')
}

async function changePin() {
  pinError.value = null
  if (nextPin.value !== confirmPin.value) {
    pinError.value = 'The new PIN entries do not match.'
    return
  }
  busy.value = true
  try {
    await offline.changePin(currentPin.value, nextPin.value)
    showChangePin.value = false
    currentPin.value = ''
    nextPin.value = ''
    confirmPin.value = ''
    ui.success('PIN changed')
  } catch (error) {
    pinError.value = error instanceof Error ? error.message : String(error)
  } finally {
    busy.value = false
  }
}

async function resetLocalVault() {
  if (!window.confirm('Reset the offline vault and permanently delete every unsynced sale on this device?')) return
  try {
    await offline.reset()
    pending.value = []
    ui.success('Offline vault reset')
  } catch (error) {
    ui.error('Could not reset vault', error instanceof Error ? error.message : String(error))
  }
}

async function removeRecord(record: OfflineCheckout) {
  if (!window.confirm(`Delete saved sale ${record.order_label}? It will never be posted.`)) return
  await offline.removePending(record.id)
  await loadPending()
  ui.notify('Saved sale deleted')
}

async function registerThisDevice() {
  if (!auth.activeBranchId) return
  registering.value = true
  try {
    await offline.ensureDevice(auth.activeBranchId)
    ui.success('This browser is registered', 'Offline sales can now be saved and synced from this device.')
  } catch (error) {
    ui.error('Could not register device', error instanceof Error ? error.message : String(error))
  } finally {
    registering.value = false
  }
}

async function checkStorage() {
  if (!navigator.storage?.persisted) {
    persisted.value = false
    return
  }
  persisted.value = await navigator.storage.persisted()
}

async function requestPersistence() {
  if (!navigator.storage?.persist) {
    ui.notify('Storage persistence is not supported by this browser')
    return
  }
  persisted.value = await navigator.storage.persist()
  ui.notify(persisted.value ? 'Offline storage protected' : 'The browser declined storage protection')
}

async function signOut() {
  if (offline.hasPending && !window.confirm('You have unsynced sales. Sign out anyway? They stay encrypted on this device.')) return
  await auth.signOut()
  await router.replace({ name: 'login' })
}

watch(
  () => offline.unlocked,
  () => void loadPending(),
)
onMounted(async () => {
  await offline.init()
  await loadPending()
  await checkStorage()
})
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">Account &amp; device</p>
        <h1>More</h1>
        <p class="subtle">Your access, encrypted offline ledger, and business controls.</p>
      </div>
      <span class="pill" :class="ui.online ? 'success' : 'warning'">{{ connectionLabel }}</span>
    </div>

    <div class="more-grid">
      <article class="panel profile-card">
        <div class="profile-avatar">{{ auth.displayName.slice(0, 1).toUpperCase() }}</div>
        <div>
          <p class="eyebrow">{{ auth.role?.replace('_', ' ') ?? 'No role' }}</p>
          <h2>{{ auth.displayName }}</h2>
          <p class="subtle">{{ auth.email }}</p>
        </div>
        <div class="key-values compact">
          <div><span>Business</span><b>{{ auth.activeGroup?.name ?? '—' }}</b></div>
          <div><span>Shop</span><b>{{ auth.activeShop?.name ?? '—' }}</b></div>
          <div><span>Branch</span><b>{{ auth.activeBranch?.name ?? '—' }}</b></div>
          <div><span>Business date</span><b>{{ manilaDate() }}</b></div>
        </div>
        <button type="button" class="secondary" @click="signOut">Sign out</button>
      </article>

      <article class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">Offline safety</p><h2>Encrypted PIN vault</h2></div>
          <span class="status-badge" :class="offline.unlocked ? 'completed' : offline.vaultExists ? 'needs_review' : 'neutral'">
            {{ offline.unlocked ? 'Unlocked' : offline.vaultExists ? 'Locked' : 'Not set up' }}
          </span>
        </div>
        <p class="subtle">
          Offline sales are encrypted with AES-GCM using a PIN-derived key. The PIN never leaves this device.
        </p>
        <div class="key-values compact">
          <div><span>Saved sales</span><b>{{ offline.pendingCount }}</b></div>
          <div><span>Value waiting</span><b>{{ formatPeso(pendingTotal) }}</b></div>
          <div><span>Last sync</span><b>{{ offline.lastSyncedAt ? formatDateTime(offline.lastSyncedAt) : 'Not yet' }}</b></div>
        </div>
        <div class="button-row">
          <button v-if="!offline.vaultExists || !offline.unlocked" type="button" class="primary" @click="showVault = true">
            {{ offline.vaultExists ? 'Unlock vault' : 'Create PIN' }}
          </button>
          <button v-else type="button" class="secondary" @click="offline.lock(); loadPending()">Lock vault</button>
          <button v-if="offline.vaultExists && offline.unlocked" type="button" class="secondary" @click="showChangePin = true">Change PIN</button>
          <button v-if="offline.vaultExists" type="button" class="secondary destructive-outline" @click="resetLocalVault">Reset vault</button>
        </div>
        <p v-if="offline.lastSyncError" class="form-error">{{ offline.lastSyncError }}</p>

        <div class="sub-section">
          <div class="panel-title"><div><p class="eyebrow">Pending</p><h2>Saved offline sales</h2></div>
            <button type="button" class="mini-button approve" :disabled="!offline.unlocked || !offline.pendingCount || offline.syncing" @click="syncNow">
              {{ offline.syncing ? 'Syncing…' : 'Sync now' }}
            </button>
          </div>
          <p v-if="!offline.unlocked && offline.pendingCount" class="callout warning">Unlock the vault to view or sync {{ offline.pendingCount }} saved sale(s).</p>
          <p v-else-if="loadingPending" class="empty-state">Reading encrypted queue…</p>
          <p v-else-if="!pending.length" class="empty-state">No saved sales on this device.</p>
          <div v-else class="pending-list">
            <div v-for="record in pending" :key="record.id" class="pending-item">
              <div>
                <strong>{{ record.order_label }} · {{ formatPeso(record.total_centavos) }}</strong>
                <small>{{ formatDateTime(record.captured_at) }} · sequence {{ record.local_sequence }}</small>
              </div>
              <button type="button" class="mini-button reject" @click="removeRecord(record)">Delete</button>
            </div>
          </div>
        </div>
      </article>

      <article class="panel">
        <div class="panel-title"><div><p class="eyebrow">This browser</p><h2>Offline device</h2></div></div>
        <div v-if="offline.currentDevice" class="key-values compact">
          <div><span>Registration</span><b>{{ offline.currentDevice.device_label }}</b></div>
          <div><span>Registered</span><b>{{ formatDateTime(offline.currentDevice.created_at) }}</b></div>
          <div><span>Last seen</span><b>{{ offline.currentDevice.last_seen_at ? formatDateTime(offline.currentDevice.last_seen_at) : 'This session' }}</b></div>
        </div>
        <p v-else class="callout warning">
          This browser is not registered for {{ auth.activeBranch?.name ?? 'a branch' }}. Register while online before taking offline sales.
        </p>
        <div class="button-row">
          <button v-if="!offline.currentDevice" type="button" class="primary" :disabled="registering || !ui.online || !auth.activeBranchId" @click="registerThisDevice">
            {{ registering ? 'Registering…' : 'Register this browser' }}
          </button>
          <RouterLink v-if="auth.canManageBranch" :to="{ name: 'admin' }" class="secondary">Manage devices</RouterLink>
        </div>
        <div class="sub-section">
          <div class="panel-title"><div><p class="eyebrow">Storage</p><h2>On-device data</h2></div></div>
          <div class="key-values compact">
            <div><span>Persistence</span><b>{{ storageLabel }}</b></div>
            <div><span>Pending encrypted</span><b>{{ offline.pendingCount }}</b></div>
          </div>
          <button type="button" class="secondary small" @click="requestPersistence">Protect offline storage</button>
        </div>
      </article>

      <article class="panel">
        <div class="panel-title"><div><p class="eyebrow">Operations</p><h2>Shortcuts</h2></div></div>
        <div class="link-grid">
          <RouterLink :to="{ name: 'production' }"><b>Production</b><span>Batch yield</span></RouterLink>
          <RouterLink :to="{ name: 'cash' }"><b>Cash drawer</b><span>Shifts</span></RouterLink>
          <RouterLink :to="{ name: 'expenses' }"><b>Expenses</b><span>Operating costs</span></RouterLink>
          <RouterLink v-if="auth.canManageBranch" :to="{ name: 'corrections' }"><b>Corrections</b><span>Voids &amp; refunds</span></RouterLink>
          <RouterLink v-if="auth.canViewReports" :to="{ name: 'reports' }"><b>Reports</b><span>Profit</span></RouterLink>
          <RouterLink v-if="auth.isOwner" :to="{ name: 'admin' }"><b>Admin</b><span>Configuration</span></RouterLink>
        </div>
      </article>
    </div>

    <VaultDialog v-if="showVault" @close="showVault = false" @ready="onVaultReady" />

    <AppModal v-if="showChangePin" title="Change offline PIN" subtitle="Existing saved sales remain encrypted with the new PIN." @close="showChangePin = false">
      <form class="form-stack" @submit.prevent="changePin">
        <label><span>Current PIN</span><input v-model="currentPin" type="password" inputmode="numeric" maxlength="8" required autofocus /></label>
        <label><span>New PIN</span><input v-model="nextPin" type="password" inputmode="numeric" maxlength="8" required /></label>
        <label><span>Confirm new PIN</span><input v-model="confirmPin" type="password" inputmode="numeric" maxlength="8" required /></label>
        <p v-if="pinError" class="form-error">{{ pinError }}</p>
        <div class="dialog-actions">
          <button type="button" class="secondary" @click="showChangePin = false">Cancel</button>
          <button type="submit" class="primary" :disabled="busy || nextPin.length < 4">{{ busy ? 'Saving…' : 'Change PIN' }}</button>
        </div>
      </form>
    </AppModal>
  </section>
</template>
