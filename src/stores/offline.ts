import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import { registerDevice, syncOfflineCheckout } from '../lib/api'
import {
  changeVaultPin,
  clearOfflineCheckouts,
  countOfflineCheckouts,
  createVault,
  deleteOfflineCheckout,
  hasVault,
  isVaultUnlocked,
  listOfflineCheckouts,
  lockVault,
  queueOfflineCheckout,
  resetVault,
  unlockVault,
  vaultUserId,
} from '../lib/offline-vault'
import type { OfflineCheckout } from '../lib/types'
import { useAuthStore } from './auth'
import { useUiStore } from './ui'

export interface SyncSummary {
  accepted: number
  needsReview: number
}

function deviceKey(branchId: string) {
  return `benta.device.${branchId}`
}

function sequenceKey(userId: string) {
  return `benta.sequence.${userId}`
}

function nextSequence(userId: string): number {
  const current = Number(localStorage.getItem(sequenceKey(userId)) ?? '0')
  const next = Number.isFinite(current) ? current + 1 : 1
  localStorage.setItem(sequenceKey(userId), String(next))
  return next
}

function defaultDeviceLabel(): string {
  const platform = navigator.userAgent.includes('Mac')
    ? 'Mac'
    : navigator.userAgent.includes('iPhone') || navigator.userAgent.includes('iPad')
      ? 'iOS'
      : navigator.userAgent.includes('Android')
        ? 'Android'
        : navigator.userAgent.includes('Windows')
          ? 'Windows'
          : 'Web'
  return `${platform} browser`
}

export const useOfflineStore = defineStore('offline', () => {
  const auth = useAuthStore()
  const ui = useUiStore()
  const initialized = ref(false)
  const busy = ref(false)
  const syncing = ref(false)
  const vaultExists = ref(false)
  const unlocked = ref(false)
  const pendingCount = ref(0)
  const lastSyncError = ref<string | null>(null)
  const lastSyncedAt = ref<string | null>(null)

  const currentDevice = computed(() => {
    if (!auth.activeBranchId) return null
    const id = localStorage.getItem(deviceKey(auth.activeBranchId))
    if (!id) return null
    return auth.devices.find((device) => device.id === id) ?? null
  })

  const currentDeviceId = computed(() => currentDevice.value?.id ?? null)
  const hasPending = computed(() => pendingCount.value > 0)
  const needsUnlock = computed(() => vaultExists.value && !unlocked.value)
  const requiresSetup = computed(() => !vaultExists.value)

  async function refreshPending() {
    pendingCount.value = await countOfflineCheckouts()
  }

  async function init() {
    if (initialized.value) return
    busy.value = true
    try {
      vaultExists.value = await hasVault()
      unlocked.value = isVaultUnlocked()
      await refreshPending()
      const owner = await vaultUserId()
      if (vaultExists.value && (!auth.user || owner !== auth.user.id)) {
        lockVault()
        unlocked.value = false
      }
      initialized.value = true
    } finally {
      busy.value = false
    }
  }

  async function setupPin(pin: string) {
    if (!auth.user) throw new Error('Sign in first.')
    busy.value = true
    try {
      await createVault(pin, auth.user.id)
      vaultExists.value = true
      unlocked.value = true
      await refreshPending()
    } finally {
      busy.value = false
    }
  }

  async function unlock(pin: string) {
    if (!auth.user) throw new Error('Sign in first.')
    busy.value = true
    try {
      await unlockVault(pin, auth.user.id)
      unlocked.value = true
      await refreshPending()
      lastSyncError.value = null
    } finally {
      busy.value = false
    }
  }

  async function changePin(currentPin: string, nextPin: string) {
    if (!auth.user) throw new Error('Sign in first.')
    busy.value = true
    try {
      await changeVaultPin(currentPin, nextPin, auth.user.id)
      unlocked.value = true
    } finally {
      busy.value = false
    }
  }

  function lock() {
    lockVault()
    unlocked.value = false
  }

  async function reset() {
    busy.value = true
    try {
      await resetVault()
      vaultExists.value = false
      unlocked.value = false
      pendingCount.value = 0
      lastSyncError.value = null
    } finally {
      busy.value = false
    }
  }

  async function wipeLocalData() {
    await resetVault()
    for (const branch of auth.branches) {
      localStorage.removeItem(deviceKey(branch.id))
    }
    vaultExists.value = false
    unlocked.value = false
    pendingCount.value = 0
  }

  async function inspectDevice() {
    const wiped = auth.devices.some(
      (device) =>
        Boolean(device.wipe_requested_at) &&
        localStorage.getItem(deviceKey(device.branch_id)) === device.id,
    )
    if (wiped) {
      await wipeLocalData()
      ui.notify('Device wiped', 'An owner requested a remote wipe. Local sales and PIN vault were removed.', 'warning')
      return
    }
    if (!auth.activeBranchId) return
    const id = localStorage.getItem(deviceKey(auth.activeBranchId))
    if (!id) return
    const device = auth.devices.find((item) => item.id === id)
    if (!device) localStorage.removeItem(deviceKey(auth.activeBranchId))
  }

  async function ensureDevice(branchId: string, label?: string): Promise<string> {
    const stored = localStorage.getItem(deviceKey(branchId))
    if (stored) {
      const device = auth.devices.find((item) => item.id === stored)
      if (device && !device.wipe_requested_at) return device.id
      localStorage.removeItem(deviceKey(branchId))
    }
    if (!navigator.onLine) {
      throw new Error('This browser is not registered for the branch. Register it while online before taking offline sales.')
    }
    const deviceId = await registerDevice(branchId, (label ?? defaultDeviceLabel()).slice(0, 80))
    localStorage.setItem(deviceKey(branchId), deviceId)
    await auth.refreshContext()
    return deviceId
  }

  async function queueSale(record: OfflineCheckout) {
    if (!unlocked.value) throw new Error('Unlock the offline vault with your PIN before taking an offline sale.')
    await queueOfflineCheckout(record)
    await refreshPending()
  }

  function createRecord(input: {
    branchId: string
    deviceId: string
    paymentMethodId: string
    paymentReference: string | null
    items: OfflineCheckout['items']
    discountCentavos: number
    discountReason: string | null
    tenderedCentavos: number | null
    configRevision: number
    totalCentavos: number
    orderLabel: string
  }): OfflineCheckout {
    if (!auth.user) throw new Error('Sign in first.')
    return {
      id: crypto.randomUUID(),
      captured_at: new Date().toISOString(),
      branch_id: input.branchId,
      device_id: input.deviceId,
      payment_method_id: input.paymentMethodId,
      payment_reference: input.paymentReference,
      items: input.items,
      discount_centavos: input.discountCentavos,
      discount_reason: input.discountReason,
      tendered_centavos: input.tenderedCentavos,
      config_revision: input.configRevision,
      local_sequence: nextSequence(auth.user.id),
      total_centavos: input.totalCentavos,
      order_label: input.orderLabel,
    }
  }

  async function listPending(branchId?: string) {
    if (!unlocked.value) throw new Error('Unlock the offline vault to view saved sales.')
    return listOfflineCheckouts(branchId)
  }

  async function removePending(id: string) {
    await deleteOfflineCheckout(id)
    await refreshPending()
  }

  async function syncPending(branchId?: string): Promise<SyncSummary> {
    if (syncing.value) return { accepted: 0, needsReview: 0 }
    if (!navigator.onLine) throw new Error('Still offline. Sales stay encrypted on this device.')
    if (!unlocked.value) throw new Error('Unlock the offline vault to sync saved sales.')
    syncing.value = true
    lastSyncError.value = null
    const summary: SyncSummary = { accepted: 0, needsReview: 0 }
    try {
      const records = await listOfflineCheckouts(branchId)
      for (const record of records) {
        try {
          const orderId = await syncOfflineCheckout(record)
          await deleteOfflineCheckout(record.id)
          if (orderId) summary.accepted += 1
          else summary.needsReview += 1
        } catch (error) {
          lastSyncError.value = error instanceof Error ? error.message : String(error)
          break
        }
      }
      if (summary.accepted > 0 || summary.needsReview > 0) lastSyncedAt.value = new Date().toISOString()
      await refreshPending()
      return summary
    } finally {
      syncing.value = false
    }
  }

  async function clearQueue() {
    busy.value = true
    try {
      await clearOfflineCheckouts()
      await refreshPending()
    } finally {
      busy.value = false
    }
  }

  return {
    initialized,
    busy,
    syncing,
    vaultExists,
    unlocked,
    pendingCount,
    hasPending,
    needsUnlock,
    requiresSetup,
    lastSyncError,
    lastSyncedAt,
    currentDevice,
    currentDeviceId,
    init,
    setupPin,
    unlock,
    changePin,
    lock,
    reset,
    inspectDevice,
    ensureDevice,
    queueSale,
    createRecord,
    listPending,
    removePending,
    syncPending,
    refreshPending,
    clearQueue,
  }
})
