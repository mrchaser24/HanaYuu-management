<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import VaultDialog from '../components/VaultDialog.vue'
import { getCashShifts, recordCheckout } from '../lib/api'
import { formatPeso, formatPesoInput, parsePesoInput } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useCartStore } from '../stores/cart'
import { useCatalogStore } from '../stores/catalog'
import { useOfflineStore } from '../stores/offline'
import { useUiStore } from '../stores/ui'
import type { CashShift, PaymentMethod } from '../lib/types'

const auth = useAuthStore()
const cart = useCartStore()
const catalog = useCatalogStore()
const offline = useOfflineStore()
const ui = useUiStore()

const selectedMethodId = ref<string | null>(null)
const tenderedInput = ref('')
const reference = ref('')
const showDiscount = ref(false)
const discountInput = ref('')
const discountReason = ref('')
const busy = ref(false)
const shifts = ref<CashShift[]>([])
const receipt = ref<{
  id: string
  offline: boolean
  total: number
  change: number
  method: string
} | null>(null)
const showVault = ref(false)
const retryAfterVault = ref(false)

const methods = computed(() => catalog.paymentMethods)
const selectedMethod = computed<PaymentMethod | null>(
  () => methods.value.find((method) => method.id === selectedMethodId.value) ?? methods.value[0] ?? null,
)
const isCash = computed(() => selectedMethod.value?.kind === 'cash')
const tenderedCentavos = computed(() => parsePesoInput(tenderedInput.value))
const change = computed(() => Math.max(tenderedCentavos.value - cart.totalCentavos, 0))
const openShift = computed(() =>
  shifts.value.find((shift) => !shift.closed_at && shift.cashier_id === auth.user?.id),
)
const referenceRequired = computed(() => Boolean(selectedMethod.value?.requires_reference))
const canSubmit = computed(() => {
  if (!catalog.catalog || !selectedMethod.value || busy.value) return false
  if (!cart.ready) return false
  if (isCash.value && tenderedCentavos.value < cart.totalCentavos) return false
  if (!isCash.value && referenceRequired.value && reference.value.trim().length < 2) return false
  return true
})
const activeDiscount = computed({
  get: () => showDiscount.value,
  set: (value: boolean) => {
    showDiscount.value = value
    if (!value) {
      discountInput.value = ''
      discountReason.value = ''
      cart.clearDiscount()
    }
  },
})

function applyTendered(value: number) {
  tenderedInput.value = formatPesoInput(value)
}

function updateDiscount() {
  if (!showDiscount.value) return
  cart.setDiscount(parsePesoInput(discountInput.value), discountReason.value)
}

watch([discountInput, discountReason, showDiscount], updateDiscount)
watch(
  () => cart.totalCentavos,
  (total) => {
    if (!tenderedInput.value || tenderedCentavos.value < total) tenderedInput.value = formatPesoInput(total)
  },
  { immediate: true },
)
watch(
  methods,
  (list) => {
    if (!list.some((method) => method.id === selectedMethodId.value)) selectedMethodId.value = list[0]?.id ?? null
  },
  { immediate: true },
)
watch(
  () => catalog.error,
  (error) => {
    if (error) ui.notify('Menu not refreshed', error, 'warning')
  },
)
async function load() {
  if (!auth.activeBranchId) return
  await catalog.load(auth.activeBranchId)
  if (catalog.products.length) {
    for (const line of cart.lines) {
      const fresh = catalog.products.find((product) => product.id === line.product.id)
      if (fresh) cart.replaceProduct(line.product.id, fresh)
    }
  }
  if (navigator.onLine) {
    try {
      shifts.value = await getCashShifts(auth.activeBranchId)
    } catch {
      shifts.value = []
    }
  }
}

function orderNumber(id: string) {
  return `#${id.slice(0, 8).toUpperCase()}`
}

function lineSubtotal(line: (typeof cart.lines)[number]) {
  return line.product.price_centavos * line.quantity
}

async function attachDevice(): Promise<string | null> {
  if (!auth.activeBranchId) return null
  if (offline.currentDeviceId) return offline.currentDeviceId
  if (!navigator.onLine) {
    throw new Error('This browser is not registered for offline sales. Register it while online first.')
  }
  try {
    return await offline.ensureDevice(auth.activeBranchId)
  } catch {
    return null
  }
}

async function submit() {
  if (!canSubmit.value || !auth.activeBranchId || !selectedMethod.value) return
  busy.value = true
  try {
    const deviceId = await attachDevice()
    if (!navigator.onLine) {
      if (!deviceId) throw new Error('This browser needs to be registered while online before taking offline sales.')
      if (!offline.unlocked) {
        retryAfterVault.value = true
        showVault.value = true
        return
      }
      const record = offline.createRecord({
        branchId: auth.activeBranchId,
        deviceId,
        paymentMethodId: selectedMethod.value.id,
        paymentReference: reference.value.trim() || null,
        items: cart.payload(),
        discountCentavos: cart.discountCentavos,
        discountReason: cart.discountReason.trim() || null,
        tenderedCentavos: isCash.value ? tenderedCentavos.value : null,
        configRevision: catalog.configRevision,
        totalCentavos: cart.totalCentavos,
        orderLabel: orderNumber(crypto.randomUUID()),
      })
      await offline.queueSale(record)
      receipt.value = {
        id: record.order_label,
        offline: true,
        total: cart.totalCentavos,
        change: isCash.value ? Math.max((record.tendered_centavos ?? 0) - cart.totalCentavos, 0) : 0,
        method: selectedMethod.value.name,
      }
      resetOrder()
      ui.success('Sale saved securely', 'It will sync when this device is online and unlocked.')
      return
    }

    const orderId = await recordCheckout({
      branchId: auth.activeBranchId,
      deviceId,
      requestId: crypto.randomUUID(),
      paymentMethodId: selectedMethod.value.id,
      paymentReference: reference.value.trim() || null,
      items: cart.payload(),
      discountCentavos: cart.discountCentavos,
      discountReason: cart.discountReason.trim() || null,
      tenderedCentavos: isCash.value ? tenderedCentavos.value : null,
      capturedAt: new Date().toISOString(),
      configRevision: catalog.configRevision,
    })
    receipt.value = {
      id: orderNumber(orderId),
      offline: false,
      total: cart.totalCentavos,
      change: isCash.value ? change.value : 0,
      method: selectedMethod.value.name,
    }
    resetOrder()
    ui.success('Sale completed', `${receipt.value.id} · ${formatPeso(receipt.value.total)}`)
    void catalog.load(auth.activeBranchId, true)
    if (auth.activeBranchId) {
      try {
        shifts.value = await getCashShifts(auth.activeBranchId)
      } catch {
        return
      }
    }
  } catch (error) {
    ui.error('Sale not completed', error instanceof Error ? error.message : String(error))
  } finally {
    busy.value = false
  }
}

function resetOrder() {
  cart.clear()
  reference.value = ''
  showDiscount.value = false
  discountInput.value = ''
  discountReason.value = ''
  retryAfterVault.value = false
  tenderedInput.value = formatPesoInput(0)
}

async function onVaultReady() {
  showVault.value = false
  if (retryAfterVault.value) {
    retryAfterVault.value = false
    await submit()
  }
}

onMounted(load)
watch(() => auth.activeBranchId, () => void load())
</script>

<template>
  <section class="pos-layout">
    <div class="pos-products">
      <div class="section-heading">
        <div>
          <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
          <h1>Cashier</h1>
          <p class="subtle">{{ catalog.stale ? 'Using the last saved menu.' : 'Tap a product to build the order.' }}</p>
        </div>
        <span v-if="!ui.online" class="pill warning">Offline mode</span>
        <span v-else-if="!openShift" class="pill warning">No open shift</span>
        <span v-else class="pill success">Shift open</span>
      </div>

      <div v-if="!auth.activeBranchId" class="callout warning">Assign a branch before taking sales.</div>
      <div v-else-if="catalog.loading && !catalog.catalog" class="panel loading-panel">Loading menu…</div>
      <div v-else-if="catalog.error && !catalog.catalog" class="callout danger">
        {{ catalog.error }}
        <button class="text-link" type="button" @click="load">Try again</button>
      </div>
      <div v-else class="product-grid">
        <button
          v-for="product in catalog.products"
          :key="product.id"
          type="button"
          class="product-card"
          :disabled="!product.available || !product.stock_available"
          @click="cart.addProduct(product)"
        >
          <span class="product-icon">{{ product.stock_model === 'batch_produced' ? '▦' : 'B' }}</span>
          <strong>{{ product.name }}</strong>
          <small>{{ product.description || 'No description yet' }}</small>
          <b>{{ formatPeso(product.price_centavos) }}</b>
          <div class="product-meta">
            <em v-if="product.flavor_choices">{{ product.flavor_choices }} flavor{{ product.flavor_choices > 1 ? 's' : '' }}</em>
            <em v-else>No options</em>
            <em v-if="product.stock_model === 'batch_produced'">{{ product.stock_quantity ?? 0 }} left</em>
            <em v-else-if="!product.recipe_complete" class="estimate">Estimate cost</em>
          </div>
          <span v-if="!product.available" class="product-unavailable">Unavailable</span>
        </button>
      </div>
      <article v-if="openShift" class="panel shift-strip">
        <div>
          <p class="eyebrow">Your shift</p>
          <strong>Opened with {{ formatPeso(openShift.opening_cash_centavos) }}</strong>
        </div>
        <div><span>Expected cash</span><b>{{ formatPeso(openShift.current_expected_cash_centavos) }}</b></div>
        <RouterLink :to="{ name: 'cash' }" class="text-link">Manage drawer</RouterLink>
      </article>
      <article v-else class="callout warning">
        No open cash drawer for you at this branch. You can still sell, but open a shift in Cash drawer for accurate
        reconciliation.
        <RouterLink :to="{ name: 'cash' }" class="text-link">Open shift</RouterLink>
      </article>
    </div>

    <aside class="cart-panel" aria-label="Cart">
      <div class="cart-title">
        <div><p class="eyebrow">Current order</p><h2>{{ cart.cartCount }} item{{ cart.cartCount === 1 ? '' : 's' }}</h2></div>
        <button v-if="cart.lines.length" class="link-button" type="button" @click="resetOrder">Clear</button>
      </div>
      <div v-if="!cart.lines.length" class="empty-cart">Choose a product to begin an order.</div>
      <div v-else class="cart-lines">
        <article v-for="line in cart.lines" :key="line.product.id" class="cart-line">
          <div class="line-main">
            <strong>{{ line.product.name }}</strong>
            <span>{{ formatPeso(lineSubtotal(line)) }}</span>
          </div>
          <div class="line-controls">
            <div class="quantity">
              <button type="button" @click="cart.setQuantity(line.product.id, line.quantity - 1)">−</button>
              <b>{{ line.quantity }}</b>
              <button type="button" @click="cart.setQuantity(line.product.id, line.quantity + 1)">+</button>
            </div>
            <small :class="{ invalid: line.options.length !== line.product.flavor_choices }">
              {{ line.options.length }}/{{ line.product.flavor_choices }} selected
            </small>
          </div>
          <div v-if="line.product.options.length" class="flavors">
            <button
              v-for="option in line.product.options"
              :key="option.id"
              type="button"
              :class="{ selected: line.options.some((selected) => selected.id === option.id) }"
              :disabled="
                !line.options.some((selected) => selected.id === option.id) &&
                line.options.length >= line.product.flavor_choices
              "
              @click="cart.toggleOption(line.product.id, option)"
            >
              {{ option.name }}
            </button>
          </div>
        </article>
      </div>

      <div class="checkout">
        <div class="total"><span>Subtotal</span><strong>{{ formatPeso(cart.subtotalCentavos) }}</strong></div>
        <div class="discount-toggle">
          <label class="check-row">
            <input v-model="activeDiscount" type="checkbox" />
            <span>Apply order discount</span>
          </label>
        </div>
        <div v-if="showDiscount" class="discount-fields">
          <input v-model="discountInput" inputmode="decimal" placeholder="Discount in ₱" />
          <input v-model="discountReason" placeholder="Reason (required)" maxlength="120" />
        </div>
        <div class="total final"><span>Total</span><strong>{{ formatPeso(cart.totalCentavos) }}</strong></div>

        <div class="payment-switch" :class="{ stacked: methods.length > 2 }">
          <button
            v-for="method in methods"
            :key="method.id"
            type="button"
            :class="{ active: selectedMethod?.id === method.id }"
            @click="selectedMethodId = method.id"
          >
            {{ method.name }}
          </button>
        </div>
        <label v-if="isCash" class="tendered">
          Cash received
          <input v-model="tenderedInput" inputmode="decimal" placeholder="0.00" />
          <span>Change: {{ formatPeso(change) }}</span>
          <div class="quick-cash">
            <button type="button" @click="applyTendered(cart.totalCentavos)">Exact</button>
            <button type="button" @click="applyTendered(50000)">₱500</button>
            <button type="button" @click="applyTendered(100000)">₱1,000</button>
          </div>
        </label>
        <label v-else class="tendered">
          {{ selectedMethod?.name }} reference
          <input v-model="reference" placeholder="Reference number" maxlength="80" />
        </label>
        <p v-if="cart.invalidLines.length" class="form-note">
          Select {{ cart.invalidLines[0]?.product.flavor_choices }} flavor(s) for {{ cart.invalidLines[0]?.product.name }}.
        </p>
        <p v-if="cart.discountInvalid" class="form-note">Add a reason and keep the discount within the subtotal.</p>
        <p v-if="isCash && cart.lines.length && tenderedCentavos < cart.totalCentavos" class="form-note">
          Cash received is below the total.
        </p>
        <button class="primary checkout-button" type="button" :disabled="!canSubmit" @click="submit">
          {{ busy ? 'Saving…' : ui.online ? 'Complete sale' : 'Save sale for sync' }}
        </button>
        <p class="secure-note">Prices, stock, and totals are verified by the server before posting.</p>
      </div>
    </aside>

    <AppModal v-if="receipt" title="Sale recorded" subtitle="Give the customer their change and receipt." @close="receipt = null">
      <div class="receipt-card">
        <p class="eyebrow">{{ receipt.offline ? 'Saved offline' : 'Completed' }}</p>
        <strong class="receipt-id">{{ receipt.id }}</strong>
        <div><span>Payment</span><b>{{ receipt.method }}</b></div>
        <div><span>Total</span><b>{{ formatPeso(receipt.total) }}</b></div>
        <div><span>Change</span><b>{{ formatPeso(receipt.change) }}</b></div>
      </div>
      <p v-if="receipt.offline" class="form-note">
        This provisional receipt is encrypted on the device. It will receive a final order record after sync.
      </p>
      <template #footer>
        <button type="button" class="primary" @click="receipt = null">Next order</button>
      </template>
    </AppModal>

    <VaultDialog
      v-if="showVault"
      reason="Unlock your encrypted offline ledger to save this sale."
      @close="showVault = false; retryAfterVault = false"
      @ready="onVaultReady"
    />
  </section>
</template>
