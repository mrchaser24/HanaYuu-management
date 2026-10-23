import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import type { CatalogProduct, CheckoutItem, ProductOption } from '../lib/types'

interface CartLine {
  product: CatalogProduct
  quantity: number
  options: ProductOption[]
  note: string
}

export const useCartStore = defineStore('cart', () => {
  const lines = ref<CartLine[]>([])
  const discountCentavos = ref(0)
  const discountReason = ref('')
  const deliveryFeeCentavos = ref(0)

  const subtotalCentavos = computed(() =>
    lines.value.reduce((sum, line) => sum + line.product.price_centavos * line.quantity, 0),
  )
  const totalCentavos = computed(() => Math.max(subtotalCentavos.value - discountCentavos.value + deliveryFeeCentavos.value, 0))
  const cartCount = computed(() => lines.value.reduce((sum, line) => sum + line.quantity, 0))
  const isEmpty = computed(() => lines.value.length === 0)
  const invalidLines = computed(() =>
    lines.value.filter((line) => line.options.length !== line.product.flavor_choices),
  )
  const ready = computed(
    () =>
      lines.value.length > 0 &&
      invalidLines.value.length === 0 &&
      discountCentavos.value <= subtotalCentavos.value &&
      (discountCentavos.value === 0 || discountReason.value.trim().length >= 3),
  )
  const discountInvalid = computed(
    () => discountCentavos.value > subtotalCentavos.value || (discountCentavos.value > 0 && discountReason.value.trim().length < 3),
  )

  function addProduct(product: CatalogProduct): boolean {
    if (!product.active || !product.available || !product.stock_available) return false
    const existing = lines.value.find((line) => line.product.id === product.id)
    if (existing) {
      existing.quantity += 1
      return true
    }
    lines.value.push({ product, quantity: 1, options: [], note: '' })
    return true
  }

  function setQuantity(productId: string, quantity: number) {
    const line = lines.value.find((item) => item.product.id === productId)
    if (!line) return
    if (quantity <= 0) {
      removeLine(productId)
      return
    }
    line.quantity = Math.min(Math.round(quantity), 999)
  }

  function removeLine(productId: string) {
    lines.value = lines.value.filter((line) => line.product.id !== productId)
  }

  function toggleOption(productId: string, option: ProductOption) {
    const line = lines.value.find((item) => item.product.id === productId)
    if (!line) return
    const index = line.options.findIndex((item) => item.id === option.id)
    if (index >= 0) {
      line.options.splice(index, 1)
      return
    }
    if (line.options.length >= line.product.flavor_choices) return
    line.options.push(option)
  }

  function setLineOptions(productId: string, options: ProductOption[]) {
    const line = lines.value.find((item) => item.product.id === productId)
    if (!line) return
    line.options = options.slice(0, line.product.flavor_choices)
  }

  function setDiscount(centavos: number, reason: string) {
    discountCentavos.value = Math.max(0, Math.min(centavos, subtotalCentavos.value))
    discountReason.value = reason
  }

  function clearDiscount() {
    discountCentavos.value = 0
    discountReason.value = ''
  }

  function setDeliveryFee(centavos: number) {
    deliveryFeeCentavos.value = Math.max(0, Math.round(centavos))
  }

  function clearDeliveryFee() {
    deliveryFeeCentavos.value = 0
  }

  function payload(): CheckoutItem[] {
    return lines.value.map((line) => ({
      product_id: line.product.id,
      quantity: line.quantity,
      selected_options: line.options.map((option) => ({ id: option.id, name: option.name })),
    }))
  }

  function clear() {
    lines.value = []
    clearDiscount()
    clearDeliveryFee()
  }

  function replaceProduct(productId: string, product: CatalogProduct) {
    const line = lines.value.find((item) => item.product.id === productId)
    if (!line) return
    line.product = product
  }

  return {
    lines,
    discountCentavos,
    discountReason,
    deliveryFeeCentavos,
    subtotalCentavos,
    totalCentavos,
    cartCount,
    isEmpty,
    invalidLines,
    ready,
    discountInvalid,
    addProduct,
    setQuantity,
    removeLine,
    toggleOption,
    setLineOptions,
    setDiscount,
    clearDiscount,
    setDeliveryFee,
    clearDeliveryFee,
    payload,
    clear,
    replaceProduct,
  }
})
