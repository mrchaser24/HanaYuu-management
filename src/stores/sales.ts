import { ref } from 'vue'
import { defineStore } from 'pinia'
import {
  getDashboardMetrics,
  getOrderDetail,
  getPendingReviews,
  getSalesHistory,
  reviewReviewOrder,
} from '../lib/api'
import { manilaDate } from '../lib/datetime'
import type { DashboardMetrics, OrderDetail, PendingReview, SaleSummary, ScopeType } from '../lib/types'

export const useSalesStore = defineStore('sales', () => {
  const metrics = ref<DashboardMetrics | null>(null)
  const recentSales = ref<SaleSummary[]>([])
  const sales = ref<SaleSummary[]>([])
  const pendingReviews = ref<PendingReview[]>([])
  const orderDetail = ref<OrderDetail | null>(null)
  const loadingMetrics = ref(false)
  const loadingSales = ref(false)
  const loadingReviews = ref(false)
  const loadingOrder = ref(false)
  const error = ref<string | null>(null)

  async function loadMetrics(scopeType: ScopeType, scopeId: string, date = manilaDate()) {
    loadingMetrics.value = true
    error.value = null
    try {
      metrics.value = await getDashboardMetrics(scopeType, scopeId, date)
    } catch (loadError) {
      error.value = loadError instanceof Error ? loadError.message : String(loadError)
      metrics.value = null
    } finally {
      loadingMetrics.value = false
    }
  }

  async function loadRecent(branchId: string) {
    try {
      recentSales.value = await getSalesHistory(branchId, undefined, undefined, 8)
    } catch {
      recentSales.value = []
    }
  }

  async function loadSales(branchId: string, from?: string, to?: string, limit = 100) {
    loadingSales.value = true
    error.value = null
    try {
      sales.value = await getSalesHistory(branchId, from, to, limit)
    } catch (loadError) {
      error.value = loadError instanceof Error ? loadError.message : String(loadError)
      sales.value = []
    } finally {
      loadingSales.value = false
    }
  }

  async function loadPendingReviews(branchId: string) {
    loadingReviews.value = true
    try {
      pendingReviews.value = await getPendingReviews(branchId)
    } catch (loadError) {
      error.value = loadError instanceof Error ? loadError.message : String(loadError)
      pendingReviews.value = []
    } finally {
      loadingReviews.value = false
    }
  }

  async function loadOrder(orderId: string) {
    loadingOrder.value = true
    error.value = null
    try {
      orderDetail.value = await getOrderDetail(orderId)
      return orderDetail.value
    } catch (loadError) {
      error.value = loadError instanceof Error ? loadError.message : String(loadError)
      orderDetail.value = null
      throw loadError
    } finally {
      loadingOrder.value = false
    }
  }

  async function reviewOrder(orderId: string, action: 'approve' | 'void' | 'reject', reason: string) {
    await reviewReviewOrder(orderId, action, reason)
    if (orderDetail.value?.order.id === orderId) await loadOrder(orderId)
  }

  function clear() {
    metrics.value = null
    recentSales.value = []
    sales.value = []
    pendingReviews.value = []
    orderDetail.value = null
    error.value = null
  }

  return {
    metrics,
    recentSales,
    sales,
    pendingReviews,
    orderDetail,
    loadingMetrics,
    loadingSales,
    loadingReviews,
    loadingOrder,
    error,
    loadMetrics,
    loadRecent,
    loadSales,
    loadPendingReviews,
    loadOrder,
    reviewOrder,
    clear,
  }
})
