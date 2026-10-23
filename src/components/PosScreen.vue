<script setup lang="ts">
import { computed, ref } from 'vue'
import { defaultFlavors } from '../lib/catalog'
import { calculateChange, formatPeso, pesosToCentavos } from '../lib/money'
import { useBusinessStore } from '../stores/business'

const store = useBusinessStore()
const tendered = ref('')
const payment = ref<'cash' | 'gcash'>('cash')
const receipt = ref<string | null>(null)

const change = computed(() => calculateChange(pesosToCentavos(Number(tendered.value) || 0), store.cartTotalCentavos))
const cartReady = computed(() => store.cart.length > 0 && store.cart.every(store.isFlavorValid))

function completeSale() {
  const sale = store.checkout(payment.value)
  if (!sale) return
  receipt.value = sale.orderNumber
  tendered.value = ''
}
</script>

<template>
  <section class="pos-layout">
    <div class="pos-products">
      <div class="section-heading">
        <div><p class="eyebrow">{{ store.branch }}</p><h1>Cashier</h1></div>
        <span v-if="!store.isOnline" class="pill warning">Saved locally</span>
      </div>
      <div class="product-grid">
        <button v-for="product in store.products" :key="product.id" class="product-card" :disabled="!product.available" @click="store.addProduct(product)">
          <span class="product-icon">🍗</span>
          <strong>{{ product.name }}</strong>
          <small>{{ product.description }}</small>
          <b>{{ formatPeso(product.priceCentavos) }}</b>
          <em>{{ product.flavorChoices }} flavor{{ product.flavorChoices > 1 ? 's' : '' }}</em>
        </button>
      </div>
    </div>

    <aside class="cart-panel" aria-label="Cart">
      <div class="cart-title"><div><p class="eyebrow">Current order</p><h2>{{ store.cartCount }} item{{ store.cartCount === 1 ? '' : 's' }}</h2></div><button class="link-button" @click="store.clearCart">Clear</button></div>
      <div v-if="!store.cart.length" class="empty-cart">Choose an item to begin an order.</div>
      <div v-else class="cart-lines">
        <article v-for="line in store.cart" :key="line.product.id" class="cart-line">
          <div class="line-main"><strong>{{ line.product.name }}</strong><span>{{ formatPeso(line.product.priceCentavos * line.quantity) }}</span></div>
          <div class="line-controls">
            <div class="quantity"><button @click="store.updateQuantity(line.product.id, line.quantity - 1)">−</button><b>{{ line.quantity }}</b><button @click="store.updateQuantity(line.product.id, line.quantity + 1)">+</button></div>
            <small :class="{ invalid: !store.isFlavorValid(line) }">Select {{ line.product.flavorChoices }} flavor{{ line.product.flavorChoices > 1 ? 's' : '' }}</small>
          </div>
          <div class="flavors"><button v-for="flavor in defaultFlavors" :key="flavor" :class="{ selected: line.flavors.includes(flavor) }" @click="store.toggleFlavor(line.product.id, flavor)">{{ flavor }}</button></div>
        </article>
      </div>
      <div class="checkout">
        <div class="total"><span>Total</span><strong>{{ formatPeso(store.cartTotalCentavos) }}</strong></div>
        <div class="payment-switch"><button :class="{ active: payment === 'cash' }" @click="payment = 'cash'">Cash</button><button :class="{ active: payment === 'gcash' }" @click="payment = 'gcash'">GCash</button></div>
        <label v-if="payment === 'cash'" class="tendered">Cash received <input v-model="tendered" inputmode="decimal" placeholder="0.00" /><span>Change: {{ formatPeso(change) }}</span></label>
        <label v-else class="tendered">GCash reference <input placeholder="Optional reference" /></label>
        <p v-if="store.cart.length && !cartReady" class="form-note">Choose the required flavors before completing this order.</p>
        <button class="primary checkout-button" :disabled="!cartReady || (payment === 'cash' && Number(tendered || 0) * 100 < store.cartTotalCentavos)" @click="completeSale">{{ store.isOnline ? 'Complete sale' : 'Save sale for sync' }}</button>
      </div>
    </aside>

    <div v-if="receipt" class="toast"><strong>{{ receipt }}</strong><span>{{ store.isOnline ? 'Sale completed.' : 'Provisional receipt saved for synchronization.' }}</span><button @click="receipt = null">×</button></div>
  </section>
</template>
