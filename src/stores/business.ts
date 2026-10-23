import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import { wingProducts } from '../lib/catalog'
import { queuePendingSale } from '../lib/offline-outbox'
import { cartHasRequiredFlavors } from '../lib/pos'
import type { CartLine, DashboardMetrics, PaymentMethod, Product, Role, SaleRecord } from '../lib/types'

const userRole = ref<Role>('staff')
const activeBranch = ref('Downtown Branch')
const connected = ref(navigator.onLine)
const cart = ref<CartLine[]>([])
const sales = ref<SaleRecord[]>([])

window.addEventListener('online', () => { connected.value = true })
window.addEventListener('offline', () => { connected.value = false })

export const useBusinessStore = defineStore('business', () => {
  const products = ref<Product[]>(wingProducts)
  const role = computed(() => userRole.value)
  const branch = computed(() => activeBranch.value)
  const isOnline = computed(() => connected.value)
  const cartTotalCentavos = computed(() => cart.value.reduce((total, line) => total + line.product.priceCentavos * line.quantity, 0))
  const cartCount = computed(() => cart.value.reduce((count, line) => count + line.quantity, 0))
  const pendingSyncCount = computed(() => sales.value.filter((sale) => sale.status === 'pending_sync').length)
  const metrics = computed<DashboardMetrics>(() => {
    const completedSales = sales.value.filter((sale) => sale.status === 'completed')
    const todaySales = completedSales.reduce((total, sale) => total + sale.totalCentavos, 0)
    return {
      todaySalesCentavos: todaySales,
      todayProfitCentavos: Math.round(todaySales * 0.42),
      inventoryValueCentavos: 285000,
      pendingSyncCount: pendingSyncCount.value,
    }
  })

  function addProduct(product: Product) {
    const line = cart.value.find((item) => item.product.id === product.id)
    if (line) line.quantity += 1
    else cart.value.push({ product, quantity: 1, flavors: [] })
  }

  function updateQuantity(productId: string, quantity: number) {
    const line = cart.value.find((item) => item.product.id === productId)
    if (!line) return
    if (quantity < 1) cart.value = cart.value.filter((item) => item.product.id !== productId)
    else line.quantity = quantity
  }

  function toggleFlavor(productId: string, flavor: string) {
    const line = cart.value.find((item) => item.product.id === productId)
    if (!line) return
    const index = line.flavors.indexOf(flavor)
    if (index >= 0) line.flavors.splice(index, 1)
    else if (line.flavors.length < line.product.flavorChoices) line.flavors.push(flavor)
  }

  function isFlavorValid(line: CartLine) {
    return line.flavors.length === line.product.flavorChoices
  }

  function clearCart() { cart.value = [] }

  function checkout(paymentMethod: PaymentMethod): SaleRecord | null {
    if (!cartHasRequiredFlavors(cart.value)) return null
    const status = isOnline.value ? 'completed' : 'pending_sync'
    const now = new Date()
    const sale: SaleRecord = {
      id: crypto.randomUUID(),
      orderNumber: status === 'completed' ? `ORD-${String(sales.value.length + 1001).padStart(5, '0')}` : 'Pending sync',
      createdAt: now.toISOString(),
      cashierName: 'Alex Santos',
      totalCentavos: cartTotalCentavos.value,
      paymentMethod,
      status,
      items: cart.value.map((line) => ({ product: { ...line.product }, quantity: line.quantity, flavors: [...line.flavors] })),
    }
    sales.value.unshift(sale)
    if (status === 'pending_sync') {
      void queuePendingSale({
        id: sale.id,
        createdAt: sale.createdAt,
        branchId: branch.value,
        paymentMethod,
        payload: sale,
        status,
      })
    }
    clearCart()
    return sale
  }

  function setRole(nextRole: Role) { userRole.value = nextRole }
  function setBranch(nextBranch: string) { activeBranch.value = nextBranch }

  return { products, role, branch, isOnline, cart, sales, metrics, cartTotalCentavos, cartCount, pendingSyncCount, addProduct, updateQuantity, toggleFlavor, isFlavorValid, checkout, clearCart, setRole, setBranch }
})
