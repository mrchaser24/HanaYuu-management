import { openDB } from 'idb'
import type { PaymentMethod } from './types'

export interface PendingSale {
  id: string
  createdAt: string
  branchId: string
  paymentMethod: PaymentMethod
  payload: unknown
  status: 'pending_sync' | 'needs_review'
}

const database = openDB('benta-offline', 1, {
  upgrade(db) {
    if (!db.objectStoreNames.contains('pending-sales')) db.createObjectStore('pending-sales', { keyPath: 'id' })
  },
})

export const queuePendingSale = async (sale: PendingSale) => (await database).put('pending-sales', sale)
export const listPendingSales = async (): Promise<PendingSale[]> => (await database).getAll('pending-sales')
export const removePendingSale = async (id: string) => (await database).delete('pending-sales', id)
