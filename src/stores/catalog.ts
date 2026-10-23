import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import { getBranchCatalog } from '../lib/api'
import type { BranchCatalog, CatalogProduct, PaymentMethod, ProductOption } from '../lib/types'

interface CatalogCache {
  saved_at: number
  catalog: BranchCatalog
}

function cacheKey(branchId: string) {
  return `benta.catalog.${branchId}`
}

function readCache(branchId: string): CatalogCache | null {
  try {
    const raw = localStorage.getItem(cacheKey(branchId))
    if (!raw) return null
    return JSON.parse(raw) as CatalogCache
  } catch {
    return null
  }
}

function writeCache(branchId: string, catalog: BranchCatalog) {
  try {
    localStorage.setItem(cacheKey(branchId), JSON.stringify({ saved_at: Date.now(), catalog }))
  } catch {
    return
  }
}

export const useCatalogStore = defineStore('catalog', () => {
  const branchId = ref<string | null>(null)
  const catalog = ref<BranchCatalog | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  const stale = ref(false)
  const loadedAt = ref<number | null>(null)

  const products = computed<CatalogProduct[]>(() => catalog.value?.products ?? [])
  const paymentMethods = computed<PaymentMethod[]>(() => catalog.value?.payment_methods ?? [])
  const settings = computed(() => catalog.value?.settings ?? { tax_inclusive_enabled: false, tax_rate_bps: 0, receipt_footer: '' })
  const branch = computed(() => catalog.value?.branch ?? null)
  const shop = computed(() => catalog.value?.shop ?? null)
  const configRevision = computed(() => catalog.value?.shop.config_revision ?? 1)
  const activeProducts = computed(() => products.value.filter((product) => product.active && product.available))

  function optionFor(product: CatalogProduct, optionId: string): ProductOption | null {
    return product.options.find((option) => option.id === optionId) ?? null
  }

  async function load(targetBranchId: string, force = false) {
    if (!targetBranchId) return
    if (branchId.value === targetBranchId && catalog.value && !force) {
      if (loadedAt.value && Date.now() - loadedAt.value < 60_000) return
    }
    loading.value = true
    error.value = null
    stale.value = false
    branchId.value = targetBranchId
    try {
      const next = await getBranchCatalog(targetBranchId)
      catalog.value = next
      loadedAt.value = Date.now()
      writeCache(targetBranchId, next)
    } catch (loadError) {
      const cached = readCache(targetBranchId)
      if (cached) {
        catalog.value = cached.catalog
        loadedAt.value = cached.saved_at
        stale.value = true
        error.value = loadError instanceof Error ? `${loadError.message} Using the last saved menu.` : String(loadError)
      } else {
        error.value = loadError instanceof Error ? loadError.message : String(loadError)
        catalog.value = null
        throw loadError
      }
    } finally {
      loading.value = false
    }
  }

  function clear() {
    branchId.value = null
    catalog.value = null
    loadedAt.value = null
    error.value = null
    stale.value = false
  }

  return {
    branchId,
    catalog,
    products,
    activeProducts,
    paymentMethods,
    settings,
    branch,
    shop,
    configRevision,
    loading,
    error,
    stale,
    loadedAt,
    optionFor,
    load,
    clear,
  }
})
