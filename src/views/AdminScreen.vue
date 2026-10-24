<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '../components/AppModal.vue'
import {
  addMembership,
  createBranch,
  createShop,
  deleteOptionRecipe,
  deleteRecipeComponent,
  getAdminData,
  getAuditEvents,
  removeMembership,
  requestDeviceWipe,
  revokeDevice,
  setBranchProductAvailability,
  updateShopSettings,
  upsertIngredient,
  upsertOptionRecipe,
  upsertPaymentMethod,
  upsertProduct,
  upsertProductOption,
  upsertRecipeComponent,
  updateShopName,
  updateBranchName,
  setShopActive,
  setBranchActive,
} from '../lib/api'
import { formatDateTime, formatQuantity } from '../lib/datetime'
import { formatPeso, formatPesoInput, parsePesoInput } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore } from '../stores/catalog'
import { useUiStore } from '../stores/ui'
import type { AdminData, AuditEvent, PaymentKind, Role, StockModel } from '../lib/types'

type AdminTab = 'structure' | 'team' | 'menu' | 'ingredients' | 'payments' | 'settings' | 'devices' | 'audit'

const auth = useAuthStore()
const catalog = useCatalogStore()
const ui = useUiStore()

const data = ref<AdminData | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const activeTab = ref<AdminTab>('structure')
const selectedShopId = computed({
  get: () => auth.activeShopId ?? '',
  set: (shopId: string) => auth.setShop(shopId),
})

const showShop = ref(false)
const showBranch = ref(false)
const showMember = ref(false)
const showProduct = ref(false)
const showIngredient = ref(false)
const showPayment = ref(false)
const auditEvents = ref<AuditEvent[]>([])
const loadingAudit = ref(false)
const busy = ref(false)
const formError = ref<string | null>(null)

const shopName = ref('')
const newShopName = ref('')
const branchName = ref('')

// Inline shop/branch editing
const editingShopId = ref<string | null>(null)
const editShopNameValue = ref('')
const editingBranchId = ref<string | null>(null)
const editBranchNameValue = ref('')
const memberEmail = ref('')
const memberRole = ref<Role>('staff')
const memberShopId = ref('')
const memberBranchId = ref('')

const editingProductId = ref<string | null>(null)
const productForm = ref({
  name: '',
  description: '',
  price: '',
  flavorChoices: 0,
  stockModel: 'made_to_order' as StockModel,
  expectedYield: '1',
  yieldUnit: 'serving',
  pieces: '',
  riceIncluded: false,
  active: true,
  version: null as number | null,
})
const newOptionName = ref('')
const recipeIngredientId = ref('')
const recipeQuantity = ref('')
const optionRecipeOptionId = ref<string | null>(null)
const optionRecipeIngredientId = ref('')
const optionRecipeQuantity = ref('')
const optionRecipeBusy = ref(false)

const editingIngredientId = ref<string | null>(null)
const ingredientForm = ref({
  name: '',
  baseUnit: 'g' as 'g' | 'kg' | 'ml' | 'L' | 'piece',
  lowStock: '0',
  category: 'other',
  active: true,
  version: null as number | null,
})

const editingPaymentId = ref<string | null>(null)
const paymentForm = ref({
  code: '',
  name: '',
  kind: 'cash' as PaymentKind,
  requiresReference: false,
  active: true,
  sortOrder: 0,
  version: null as number | null,
})

const taxEnabled = ref(false)
const taxPercent = ref('0')
const receiptFooter = ref('')
const settingsVersion = ref<number | null>(null)

const shops = computed(() => data.value?.shops ?? [])
const currentShop = computed(() => shops.value.find((shop) => shop.id === selectedShopId.value) ?? shops.value[0] ?? null)
const shopBranches = computed(() => data.value?.branches.filter((branch) => branch.shop_id === currentShop.value?.id) ?? [])
const shopProducts = computed(() => data.value?.products.filter((product) => product.shop_id === currentShop.value?.id) ?? [])
const shopIngredients = computed(() => data.value?.ingredients.filter((ingredient) => ingredient.shop_id === currentShop.value?.id) ?? [])
const shopMethods = computed(() => data.value?.payment_methods.filter((method) => method.shop_id === currentShop.value?.id) ?? [])
const shopMembers = computed(() => {
  const branchIds = new Set(shopBranches.value.map((branch) => branch.id))
  return (data.value?.members ?? []).filter(
    (member) => member.shop_id === currentShop.value?.id || (member.branch_id && branchIds.has(member.branch_id)),
  )
})
const currentSettings = computed(() => data.value?.settings.find((settings) => settings.shop_id === currentShop.value?.id) ?? null)
const editingProduct = computed(() => shopProducts.value.find((product) => product.id === editingProductId.value) ?? null)
const editingOption = computed(
  () => editingProduct.value?.options.find((option) => option.id === optionRecipeOptionId.value) ?? null,
)
const shopDevices = computed(() => {
  const branchIds = new Set(shopBranches.value.map((branch) => branch.id))
  return (data.value?.devices ?? []).filter((device) => branchIds.has(device.branch_id))
})
const memberBranchOptions = computed(() => {
  const shop = shops.value.find((item) => item.id === memberShopId.value)
  return shop ? (data.value?.branches.filter((branch) => branch.shop_id === shop.id) ?? []) : []
})
const canAddOwner = computed(() => auth.isSuperAdmin)

function shopNameFor(id: string | null) {
  return shops.value.find((shop) => shop.id === id)?.name ?? '—'
}

function branchNameFor(id: string | null) {
  return data.value?.branches.find((branch) => branch.id === id)?.name ?? '—'
}

async function load() {
  if (!auth.activeGroup) {
    error.value = 'No business group is available for this account.'
    return
  }
  loading.value = true
  error.value = null
  try {
    data.value = await getAdminData(auth.activeGroup.id)
    if (shops.value.length && !shops.value.some((shop) => shop.id === auth.activeShopId)) {
      auth.setShop(shops.value[0].id)
    }
    syncSettingsForm()
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
  } finally {
    loading.value = false
  }
}

function syncSettingsForm() {
  shopName.value = currentShop.value?.name ?? ''
  if (!currentSettings.value) return
  taxEnabled.value = currentSettings.value.tax_inclusive_enabled
  taxPercent.value = (currentSettings.value.tax_rate_bps / 100).toFixed(2)
  receiptFooter.value = currentSettings.value.receipt_footer
  settingsVersion.value = currentSettings.value.version
}

async function refreshCatalog() {
  if (!auth.activeBranchId) return
  try {
    await catalog.load(auth.activeBranchId, true)
  } catch {
    return
  }
}

function productAvailableAtActiveBranch(productId: string) {
  return catalog.products.find((product) => product.id === productId)?.branch_available ?? true
}

async function loadAudit() {
  const branchId = auth.activeBranchId
  if (!branchId) {
    auditEvents.value = []
    return
  }
  loadingAudit.value = true
  try {
    const events = await getAuditEvents(branchId, 100)
    if (branchId === auth.activeBranchId) auditEvents.value = events
  } catch (auditError) {
    if (branchId === auth.activeBranchId) auditEvents.value = []
    ui.error('Could not load audit trail', auditError instanceof Error ? auditError.message : String(auditError))
  } finally {
    loadingAudit.value = false
  }
}

function auditLabel(action: string) {
  return action.replace(/_/g, ' ')
}

function auditMetadata(metadata: Record<string, unknown>) {
  return Object.entries(metadata)
    .map(([key, value]) => `${key.replace(/_/g, ' ')}: ${typeof value === 'string' ? value : JSON.stringify(value)}`)
    .join(' · ')
}

function startShop() {
  newShopName.value = ''
  formError.value = null
  showShop.value = true
}

async function submitShop() {
  if (!auth.activeGroup) return
  busy.value = true
  formError.value = null
  try {
    const id = await createShop(auth.activeGroup.id, newShopName.value)
    showShop.value = false
    await auth.refreshContext()
    auth.setShop(id)
    await load()
    ui.success('Shop created')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function startBranch() {
  branchName.value = ''
  formError.value = null
  showBranch.value = true
}

async function submitBranch() {
  if (!currentShop.value) return
  busy.value = true
  formError.value = null
  try {
    const id = await createBranch(currentShop.value.id, branchName.value)
    showBranch.value = false
    await auth.refreshContext()
    auth.setBranch(id)
    await load()
    ui.success('Branch created')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function startMember() {
  memberEmail.value = ''
  memberRole.value = 'staff'
  memberShopId.value = currentShop.value?.id ?? ''
  memberBranchId.value = shopBranches.value[0]?.id ?? ''
  formError.value = null
  showMember.value = true
}

async function submitMember() {
  if (!auth.activeGroup) return
  formError.value = null
  if (memberRole.value !== 'super_admin' && !memberShopId.value) {
    formError.value = 'Choose a shop for this person.'
    return
  }
  if (memberRole.value === 'staff' && !memberBranchOptions.value.some((branch) => branch.id === memberBranchId.value)) {
    formError.value = 'Choose a branch that belongs to the selected shop.'
    return
  }
  busy.value = true
  try {
    await addMembership({
      email: memberEmail.value,
      role: memberRole.value,
      groupId: auth.activeGroup.id,
      shopId: memberRole.value === 'super_admin' ? null : memberShopId.value || currentShop.value?.id || null,
      branchId: memberRole.value === 'staff' ? memberBranchId.value : null,
    })
    showMember.value = false
    await load()
    ui.success('Team member added')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

async function removeMember(memberId: string, name: string) {
  if (!window.confirm(`Remove ${name} from this business?`)) return
  try {
    await removeMembership(memberId)
    await load()
    ui.success('Team member removed')
  } catch (removeError) {
    ui.error('Could not remove member', removeError instanceof Error ? removeError.message : String(removeError))
  }
}

function startProduct(productId?: string) {
  const product = productId ? shopProducts.value.find((item) => item.id === productId) : null
  editingProductId.value = product?.id ?? null
  productForm.value = {
    name: product?.name ?? '',
    description: product?.description ?? '',
    price: product ? formatPesoInput(product.price_centavos) : '',
    flavorChoices: product?.flavor_choices ?? 0,
    stockModel: product?.stock_model ?? 'made_to_order',
    expectedYield: String(product?.expected_yield_quantity ?? 1),
    yieldUnit: product?.expected_yield_unit ?? 'serving',
    pieces: product?.pieces ? String(product.pieces) : '',
    riceIncluded: product?.rice_included ?? false,
    active: product?.active ?? true,
    version: product?.version ?? null,
  }
  newOptionName.value = ''
  recipeIngredientId.value = shopIngredients.value[0]?.id ?? ''
  recipeQuantity.value = ''
  formError.value = null
  showProduct.value = true
}

async function submitProduct() {
  if (!currentShop.value) return
  busy.value = true
  formError.value = null
  try {
    await upsertProduct({
      shopId: currentShop.value.id,
      productId: editingProductId.value,
      name: productForm.value.name,
      description: productForm.value.description,
      priceCentavos: parsePesoInput(productForm.value.price),
      flavorChoices: Number(productForm.value.flavorChoices),
      stockModel: productForm.value.stockModel,
      expectedYieldQuantity: Number(productForm.value.expectedYield) || 1,
      expectedYieldUnit: productForm.value.yieldUnit,
      pieces: productForm.value.pieces ? Number(productForm.value.pieces) : null,
      riceIncluded: productForm.value.riceIncluded,
      active: productForm.value.active,
      version: productForm.value.version,
    })
    showProduct.value = false
    await load()
    await refreshCatalog()
    ui.success('Product saved')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

async function addOption() {
  if (!editingProduct.value || newOptionName.value.trim().length < 1) return
  try {
    await upsertProductOption({
      productId: editingProduct.value.id,
      optionId: null,
      name: newOptionName.value,
      active: true,
      sortOrder: editingProduct.value.options.length,
      version: null,
    })
    const id = editingProduct.value.id
    await load()
    startProduct(id)
    await refreshCatalog()
    ui.success('Option added')
  } catch (optionError) {
    formError.value = optionError instanceof Error ? optionError.message : String(optionError)
  }
}

async function toggleOption(optionId: string, active: boolean, version: number) {
  if (!editingProduct.value) return
  try {
    await upsertProductOption({
      productId: editingProduct.value.id,
      optionId,
      name: editingProduct.value.options.find((option) => option.id === optionId)?.name ?? '',
      active: !active,
      sortOrder: editingProduct.value.options.find((option) => option.id === optionId)?.sort_order ?? 0,
      version,
    })
    const id = editingProduct.value.id
    await load()
    startProduct(id)
    await refreshCatalog()
  } catch (optionError) {
    formError.value = optionError instanceof Error ? optionError.message : String(optionError)
  }
}

async function addRecipe() {
  if (!editingProduct.value || !recipeIngredientId.value || Number(recipeQuantity.value) <= 0) return
  try {
    await upsertRecipeComponent(editingProduct.value.id, recipeIngredientId.value, Number(recipeQuantity.value))
    const id = editingProduct.value.id
    await load()
    startProduct(id)
    await refreshCatalog()
    ui.success('Recipe updated')
  } catch (recipeError) {
    formError.value = recipeError instanceof Error ? recipeError.message : String(recipeError)
  }
}

async function removeRecipe(ingredientId: string) {
  if (!editingProduct.value) return
  try {
    await deleteRecipeComponent(editingProduct.value.id, ingredientId)
    const id = editingProduct.value.id
    await load()
    startProduct(id)
    await refreshCatalog()
  } catch (recipeError) {
    formError.value = recipeError instanceof Error ? recipeError.message : String(recipeError)
  }
}

function openOptionRecipe(optionId: string) {
  optionRecipeOptionId.value = optionId
  optionRecipeIngredientId.value = shopIngredients.value[0]?.id ?? ''
  optionRecipeQuantity.value = ''
}

function closeOptionRecipe() {
  optionRecipeOptionId.value = null
  optionRecipeIngredientId.value = ''
  optionRecipeQuantity.value = ''
}

async function saveOptionRecipe() {
  if (!optionRecipeOptionId.value || !optionRecipeIngredientId.value) return
  const quantity = Number(optionRecipeQuantity.value)
  if (!Number.isFinite(quantity) || quantity <= 0) {
    ui.error('Enter a positive quantity for the option recipe')
    return
  }
  optionRecipeBusy.value = true
  try {
    await upsertOptionRecipe(optionRecipeOptionId.value, optionRecipeIngredientId.value, quantity)
    await load()
    await refreshCatalog()
    closeOptionRecipe()
    ui.success('Option recipe updated')
  } catch (recipeError) {
    ui.error('Could not update option recipe', recipeError instanceof Error ? recipeError.message : String(recipeError))
  } finally {
    optionRecipeBusy.value = false
  }
}

async function removeOptionRecipe() {
  if (!optionRecipeOptionId.value || !optionRecipeIngredientId.value) return
  optionRecipeBusy.value = true
  try {
    await deleteOptionRecipe(optionRecipeOptionId.value, optionRecipeIngredientId.value)
    await load()
    await refreshCatalog()
    closeOptionRecipe()
    ui.success('Option recipe line removed')
  } catch (recipeError) {
    ui.error('Could not remove option recipe', recipeError instanceof Error ? recipeError.message : String(recipeError))
  } finally {
    optionRecipeBusy.value = false
  }
}

async function toggleAvailability(productId: string, currentlyAvailable: boolean) {
  if (!auth.activeBranchId) return
  try {
    await setBranchProductAvailability(auth.activeBranchId, productId, !currentlyAvailable, null)
    await refreshCatalog()
    ui.success(currentlyAvailable ? 'Product hidden at this branch' : 'Product available at this branch')
  } catch (availabilityError) {
    ui.error('Could not change availability', availabilityError instanceof Error ? availabilityError.message : String(availabilityError))
  }
}

function startIngredient(ingredientId?: string) {
  const ingredient = ingredientId ? shopIngredients.value.find((item) => item.id === ingredientId) : null
  editingIngredientId.value = ingredient?.id ?? null
  ingredientForm.value = {
    name: ingredient?.name ?? '',
    baseUnit: ingredient?.base_unit ?? 'g',
    lowStock: String(ingredient?.low_stock_quantity ?? 0),
    category: ingredient?.category ?? 'other',
    active: ingredient?.active ?? true,
    version: ingredient?.version ?? null,
  }
  formError.value = null
  showIngredient.value = true
}

async function submitIngredient() {
  if (!currentShop.value) return
  busy.value = true
  formError.value = null
  try {
    await upsertIngredient({
      shopId: currentShop.value.id,
      ingredientId: editingIngredientId.value,
      name: ingredientForm.value.name,
      baseUnit: ingredientForm.value.baseUnit,
      lowStockQuantity: Number(ingredientForm.value.lowStock) || 0,
      category: ingredientForm.value.category,
      active: ingredientForm.value.active,
      version: ingredientForm.value.version,
    })
    showIngredient.value = false
    await load()
    await refreshCatalog()
    ui.success('Ingredient saved')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function startPayment(methodId?: string) {
  const method = methodId ? shopMethods.value.find((item) => item.id === methodId) : null
  editingPaymentId.value = method?.id ?? null
  paymentForm.value = {
    code: method?.code ?? '',
    name: method?.name ?? '',
    kind: method?.kind ?? 'cash',
    requiresReference: method?.requires_reference ?? false,
    active: method?.active ?? true,
    sortOrder: method?.sort_order ?? shopMethods.value.length,
    version: method?.version ?? null,
  }
  formError.value = null
  showPayment.value = true
}

async function submitPayment() {
  if (!currentShop.value) return
  busy.value = true
  formError.value = null
  try {
    await upsertPaymentMethod({
      shopId: currentShop.value.id,
      methodId: editingPaymentId.value,
      code: paymentForm.value.code,
      name: paymentForm.value.name,
      kind: paymentForm.value.kind,
      requiresReference: paymentForm.value.requiresReference,
      active: paymentForm.value.active,
      sortOrder: paymentForm.value.sortOrder,
      version: paymentForm.value.version,
    })
    showPayment.value = false
    await load()
    await refreshCatalog()
    ui.success('Payment method saved')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

async function saveSettings() {
  if (!currentShop.value) return
  busy.value = true
  formError.value = null
  try {
    await updateShopSettings({
      shopId: currentShop.value.id,
      taxInclusiveEnabled: taxEnabled.value,
      taxRateBps: Math.round(Number(taxPercent.value || 0) * 100),
      receiptFooter: receiptFooter.value,
      version: settingsVersion.value,
    })
    await load()
    await refreshCatalog()
    ui.success('Shop settings saved')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

async function updateName() {
  if (!shopName.value || !currentShop.value) return
  busy.value = true
  formError.value = null
  try {
    await updateShopName({
      shopId: currentShop.value.id,
      name: shopName.value,
      version: settingsVersion.value,
    })
    await load()
    ui.success('Shop name updated')
  } catch (submitError) {
    formError.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}

function startEditShop(shopId: string, currentName: string) {
  editingShopId.value = shopId
  editShopNameValue.value = currentName
}

function cancelEditShop() {
  editingShopId.value = null
  editShopNameValue.value = ''
}

async function saveEditShop(shopId: string) {
  const name = editShopNameValue.value.trim()
  if (!name) return
  busy.value = true
  try {
    await updateShopName({ shopId, name, version: null })
    await load()
    await auth.refreshContext()
    cancelEditShop()
    ui.success('Shop renamed')
  } catch (err) {
    ui.error('Could not rename shop', err instanceof Error ? err.message : String(err))
  } finally {
    busy.value = false
  }
}

async function toggleShopActive(shopId: string, currentlyActive: boolean) {
  const verb = currentlyActive ? 'archive' : 'restore'
  if (!window.confirm(`${currentlyActive ? 'Archive' : 'Restore'} this shop? Staff will ${currentlyActive ? 'lose access until restored' : 'regain access'}.`)) return
  busy.value = true
  try {
    await setShopActive(shopId, !currentlyActive)
    await load()
    await auth.refreshContext()
    ui.success(`Shop ${verb}d`)
  } catch (err) {
    ui.error(`Could not ${verb} shop`, err instanceof Error ? err.message : String(err))
  } finally {
    busy.value = false
  }
}

function startEditBranch(branchId: string, currentName: string) {
  editingBranchId.value = branchId
  editBranchNameValue.value = currentName
}

function cancelEditBranch() {
  editingBranchId.value = null
  editBranchNameValue.value = ''
}

async function saveEditBranch(branchId: string) {
  const name = editBranchNameValue.value.trim()
  if (!name) return
  busy.value = true
  try {
    await updateBranchName(branchId, name)
    await load()
    await auth.refreshContext()
    cancelEditBranch()
    ui.success('Branch renamed')
  } catch (err) {
    ui.error('Could not rename branch', err instanceof Error ? err.message : String(err))
  } finally {
    busy.value = false
  }
}

async function toggleBranchActive(branchId: string, currentlyActive: boolean) {
  const verb = currentlyActive ? 'archive' : 'restore'
  if (!window.confirm(`${currentlyActive ? 'Archive' : 'Restore'} this branch?`)) return
  busy.value = true
  try {
    await setBranchActive(branchId, !currentlyActive)
    await load()
    await auth.refreshContext()
    ui.success(`Branch ${verb}d`)
  } catch (err) {
    ui.error(`Could not ${verb} branch`, err instanceof Error ? err.message : String(err))
  } finally {
    busy.value = false
  }
}

async function revoke(deviceId: string, label: string) {
  if (!window.confirm(`Revoke ${label}? Offline sync from that device will stop.`)) return
  try {
    await revokeDevice(deviceId, 'Owner revoked from admin')
    await load()
    ui.success('Device revoked')
  } catch (revokeError) {
    ui.error('Could not revoke device', revokeError instanceof Error ? revokeError.message : String(revokeError))
  }
}

async function wipe(deviceId: string, label: string) {
  if (!window.confirm(`Request a remote wipe of ${label}? Local sales and the PIN vault will be removed next time it connects.`)) return
  try {
    await requestDeviceWipe(deviceId)
    await load()
    ui.success('Wipe requested')
  } catch (wipeError) {
    ui.error('Could not request wipe', wipeError instanceof Error ? wipeError.message : String(wipeError))
  }
}

watch(memberShopId, () => {
  memberBranchId.value = memberRole.value === 'staff' ? memberBranchOptions.value[0]?.id ?? '' : ''
  formError.value = null
})
watch(memberRole, (role) => {
  if (role === 'super_admin') {
    memberBranchId.value = ''
  } else if (role === 'owner') {
    memberBranchId.value = ''
    if (!shops.value.some((shop) => shop.id === memberShopId.value)) {
      memberShopId.value = currentShop.value?.id ?? shops.value[0]?.id ?? ''
    }
  } else {
    if (!shops.value.some((shop) => shop.id === memberShopId.value)) {
      memberShopId.value = currentShop.value?.id ?? shops.value[0]?.id ?? ''
    }
    if (!memberBranchOptions.value.some((branch) => branch.id === memberBranchId.value)) {
      memberBranchId.value = memberBranchOptions.value[0]?.id ?? ''
    }
  }
  formError.value = null
})
watch(selectedShopId, () => syncSettingsForm())
watch(activeTab, (tab) => {
  if (tab === 'audit') void loadAudit()
})
watch(
  () => auth.activeBranchId,
  () => {
    void refreshCatalog()
    if (activeTab.value === 'audit') void loadAudit()
  },
)
watch(
  () => auth.activeGroup?.id,
  () => void load(),
)
onMounted(async () => {
  await load()
  await refreshCatalog()
})
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ data?.group.name ?? auth.activeGroup?.name ?? 'Business' }}</p>
        <h1>Admin</h1>
        <p class="subtle">Shops, team access, menu, recipes, payments, and device controls.</p>
      </div>
      <div class="heading-actions">
        <select v-if="shops.length > 1" v-model="selectedShopId" class="compact-select" aria-label="Shop">
          <option v-for="shop in shops" :key="shop.id" :value="shop.id">{{ shop.name }}</option>
        </select>
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
      </div>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>
    <div v-if="loading && !data" class="panel loading-panel">Loading configuration…</div>
    <template v-else-if="data">
      <div class="tabs admin-tabs">
        <button type="button" :class="{ active: activeTab === 'structure' }" @click="activeTab = 'structure'">Shops &amp; branches</button>
        <button type="button" :class="{ active: activeTab === 'team' }" @click="activeTab = 'team'">Team</button>
        <button type="button" :class="{ active: activeTab === 'menu' }" @click="activeTab = 'menu'">Menu</button>
        <button type="button" :class="{ active: activeTab === 'ingredients' }" @click="activeTab = 'ingredients'">Ingredients</button>
        <button type="button" :class="{ active: activeTab === 'payments' }" @click="activeTab = 'payments'">Payments</button>
        <button type="button" :class="{ active: activeTab === 'settings' }" @click="activeTab = 'settings'">Settings</button>
        <button type="button" :class="{ active: activeTab === 'devices' }" @click="activeTab = 'devices'">Devices</button>
        <button type="button" :class="{ active: activeTab === 'audit' }" @click="activeTab = 'audit'">Audit</button>
      </div>

      <div v-if="activeTab === 'structure'" class="admin-grid">
        <article class="panel">
          <div class="panel-title">
            <div><p class="eyebrow">Group</p><h2>Shops</h2></div>
            <button v-if="auth.isSuperAdmin" type="button" class="primary small" @click="startShop">New shop</button>
          </div>
          <div v-if="!shops.length" class="empty-state">No shops in this group yet.</div>
          <div v-else class="simple-list">
            <div
              v-for="shop in shops"
              :key="shop.id"
              class="simple-row selectable"
              :class="{ selected: shop.id === selectedShopId, archived: shop.active === false }"
              @click="selectedShopId = shop.id"
            >
              <template v-if="editingShopId === shop.id">
                <input
                  v-model="editShopNameValue"
                  class="inline-edit-input"
                  maxlength="120"
                  @click.stop
                  @keydown.enter.prevent="saveEditShop(shop.id)"
                  @keydown.esc.prevent="cancelEditShop"
                />
                <div class="row-actions" @click.stop>
                  <button type="button" class="mini-button" :disabled="busy" @click="saveEditShop(shop.id)">Save</button>
                  <button type="button" class="mini-button" @click="cancelEditShop">Cancel</button>
                </div>
              </template>
              <template v-else>
                <div>
                  <strong>{{ shop.name }}</strong>
                  <small>{{ shop.timezone }}</small>
                </div>
                <div class="row-actions" @click.stop>
                  <span v-if="shop.active === false" class="status-badge rejected">Archived</span>
                  <span v-else class="status-badge neutral">{{ data.branches.filter((b) => b.shop_id === shop.id).length }} branches</span>
                  <button type="button" class="mini-button" @click="startEditShop(shop.id, shop.name)">Rename</button>
                  <button
                    type="button"
                    class="mini-button"
                    :class="shop.active === false ? '' : 'reject'"
                    :disabled="busy"
                    @click="toggleShopActive(shop.id, shop.active !== false)"
                  >{{ shop.active === false ? 'Restore' : 'Archive' }}</button>
                </div>
              </template>
            </div>
          </div>
        </article>

        <article class="panel">
          <div class="panel-title">
            <div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Branches</h2></div>
            <button type="button" class="primary small" :disabled="!currentShop" @click="startBranch">New branch</button>
          </div>
          <div v-if="!shopBranches.length" class="empty-state">No branches yet.</div>
          <div v-else class="simple-list">
            <div v-for="branch in shopBranches" :key="branch.id" class="simple-row" :class="{ archived: branch.active === false }">
              <template v-if="editingBranchId === branch.id">
                <input
                  v-model="editBranchNameValue"
                  class="inline-edit-input"
                  maxlength="120"
                  @keydown.enter.prevent="saveEditBranch(branch.id)"
                  @keydown.esc.prevent="cancelEditBranch"
                />
                <div class="row-actions">
                  <button type="button" class="mini-button" :disabled="busy" @click="saveEditBranch(branch.id)">Save</button>
                  <button type="button" class="mini-button" @click="cancelEditBranch">Cancel</button>
                </div>
              </template>
              <template v-else>
                <div>
                  <strong>{{ branch.name }}</strong>
                  <small>
                    <span v-if="branch.active === false" class="status-badge rejected" style="font-size:10px">Archived</span>
                    <span v-else-if="branch.id === auth.activeBranchId">Currently selected</span>
                    <span v-else>Branch</span>
                  </small>
                </div>
                <div class="row-actions">
                  <button v-if="branch.active !== false" type="button" class="mini-button" @click="auth.setBranch(branch.id)">Use</button>
                  <button type="button" class="mini-button" @click="startEditBranch(branch.id, branch.name)">Rename</button>
                  <button
                    type="button"
                    class="mini-button"
                    :class="branch.active === false ? '' : 'reject'"
                    :disabled="busy"
                    @click="toggleBranchActive(branch.id, branch.active !== false)"
                  >{{ branch.active === false ? 'Restore' : 'Archive' }}</button>
                </div>
              </template>
            </div>
          </div>
        </article>
      </div>

      <div v-else-if="activeTab === 'team'" class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Team access</h2></div>
          <button type="button" class="primary small" :disabled="!currentShop" @click="startMember">Add person</button>
        </div>
        <div class="callout info">Owners manage staff for their shop. Super admins can add owners and other super admins.</div>
        <div v-if="!shopMembers.length" class="empty-state">No team members besides your account.</div>
        <div v-else class="table-panel">
          <div class="data-table six-col">
            <div class="table-head"><span>Person</span><span>Role</span><span>Shop</span><span>Branch</span><span>Added</span><span></span></div>
            <div v-for="member in shopMembers" :key="member.id" class="table-row static">
              <span><b>{{ member.display_name ?? 'Unnamed' }}</b><small>{{ member.user_id.slice(0, 8) }}</small></span>
              <span><span class="status-badge neutral">{{ member.role.replace('_', ' ') }}</span></span>
              <span>{{ shopNameFor(member.shop_id) }}</span>
              <span>{{ branchNameFor(member.branch_id) }}</span>
              <span>{{ formatDateTime(member.created_at) }}</span>
              <span>
                <button type="button" class="mini-button reject" @click="removeMember(member.id, member.display_name ?? 'this person')">Remove</button>
              </span>
            </div>
          </div>
        </div>
      </div>

      <div v-else-if="activeTab === 'menu'" class="menu-admin">
        <div class="panel">
          <div class="panel-title">
            <div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Products</h2></div>
            <button type="button" class="primary small" :disabled="!currentShop" @click="startProduct()">New product</button>
          </div>
          <div v-if="!shopProducts.length" class="empty-state">No products yet.</div>
          <div v-else class="admin-product-list">
            <article v-for="product in shopProducts" :key="product.id" class="admin-product">
              <div class="admin-product-main">
                <div>
                  <p class="eyebrow">{{ product.stock_model === 'batch_produced' ? 'Batch produced' : 'Made to order' }}</p>
                  <strong>{{ product.name }} · {{ formatPeso(product.price_centavos) }}</strong>
                  <small>{{ product.description || 'No description' }}</small>
                </div>
                <span class="status-badge" :class="product.active ? 'completed' : 'rejected'">{{ product.active ? 'Active' : 'Inactive' }}</span>
              </div>
              <div class="chips">
                <span>{{ product.flavor_choices }} option{{ product.flavor_choices === 1 ? '' : 's' }}</span>
                <span>{{ product.options.length }} choices</span>
                <span>{{ product.recipe.length }} recipe line{{ product.recipe.length === 1 ? '' : 's' }}</span>
                <span v-if="!product.recipe.length" class="estimate">Estimate cost</span>
              </div>
              <div class="admin-product-actions">
                <button type="button" class="secondary small" @click="startProduct(product.id)">Edit</button>
                <button
                  v-if="auth.activeBranch && auth.activeBranch.shop_id === product.shop_id"
                  type="button"
                  class="mini-button"
                  @click="toggleAvailability(product.id, productAvailableAtActiveBranch(product.id))"
                >
                  {{ productAvailableAtActiveBranch(product.id) ? 'Hide' : 'Show' }} at {{ auth.activeBranch.name }}
                </button>
              </div>
            </article>
          </div>
        </div>
      </div>

      <div v-else-if="activeTab === 'ingredients'" class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Ingredients</h2></div>
          <button type="button" class="primary small" :disabled="!currentShop" @click="startIngredient()">New ingredient</button>
        </div>
        <div v-if="!shopIngredients.length" class="empty-state">No ingredients yet.</div>
        <div v-else class="data-table six-col">
          <div class="table-head"><span>Ingredient</span><span>Unit</span><span>Low stock</span><span>Category</span><span>Status</span><span></span></div>
          <div v-for="ingredient in shopIngredients" :key="ingredient.id" class="table-row static">
            <span><b>{{ ingredient.name }}</b></span>
            <span>{{ ingredient.base_unit }}</span>
            <span>{{ formatQuantity(ingredient.low_stock_quantity, ingredient.base_unit) }}</span>
            <span>{{ ingredient.category }}</span>
            <span><span class="status-badge" :class="ingredient.active ? 'completed' : 'rejected'">{{ ingredient.active ? 'Active' : 'Inactive' }}</span></span>
            <span><button type="button" class="mini-button" @click="startIngredient(ingredient.id)">Edit</button></span>
          </div>
        </div>
      </div>

      <div v-else-if="activeTab === 'payments'" class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Payment methods</h2></div>
          <button type="button" class="primary small" :disabled="!currentShop" @click="startPayment()">New method</button>
        </div>
        <div v-if="!shopMethods.length" class="empty-state">No payment methods configured.</div>
        <div v-else class="simple-list">
          <div v-for="method in shopMethods" :key="method.id" class="simple-row">
            <div>
              <strong>{{ method.name }} <span class="mono subtle">{{ method.code }}</span></strong>
              <small>{{ method.kind }} · {{ method.requires_reference ? 'Reference required' : 'No reference' }} · order {{ method.sort_order }}</small>
            </div>
            <div class="row-actions">
              <span class="status-badge" :class="method.active ? 'completed' : 'rejected'">{{ method.active ? 'Active' : 'Inactive' }}</span>
              <button type="button" class="mini-button" @click="startPayment(method.id)">Edit</button>
            </div>
          </div>
        </div>
      </div>

      <div v-else-if="activeTab === 'settings'" class="admin-grid">
        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Tax &amp; receipt</h2></div></div>
          <form class="form-stack" @submit.prevent="saveSettings">
            <label class="check-field">
              <input v-model="taxEnabled" type="checkbox" />
              <span>VAT is included in menu prices</span>
            </label>
            <label>
              <span>VAT rate (%)</span>
              <input v-model="taxPercent" inputmode="decimal" placeholder="12" :disabled="!taxEnabled" />
            </label>
            <label>
              <span>Receipt footer</span>
              <textarea v-model="receiptFooter" rows="3" maxlength="240" placeholder="Thank you!" />
            </label>
            <p class="form-note">Changing menu, recipe, or settings configuration makes offline sales reconcile against a new revision.</p>
            <p v-if="formError" class="form-error">{{ formError }}</p>
            <button type="submit" class="primary" :disabled="busy || !currentShop">{{ busy ? 'Saving…' : 'Save settings' }}</button>
          </form>
        </article>
        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Visibility</p><h2>Branch availability</h2></div></div>
          <p class="subtle">Product availability is managed from the Menu tab for {{ auth.activeBranch?.name ?? 'the selected branch' }}.</p>
          <div class="key-values">
            <div><span>Active branch</span><b>{{ auth.activeBranch?.name ?? 'None' }}</b></div>
            <div><span>Products</span><b>{{ shopProducts.length }}</b></div>
            <div><span>Branches</span><b>{{ shopBranches.length }}</b></div>
          </div>
        </article>
        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Visibility</p><h2>Shops Details</h2></div></div>
          <p class="subtle">Update your shop's information and settings.</p>
          <form class="form-stack" @submit.prevent="updateName">
            <label>
              <span>Shop Name</span>
              <input v-model="shopName" :placeholder="currentShop?.name || 'My Shop'" />
            </label>
            <p class="form-note">Changing shop name will update all related records.</p>
            <p v-if="formError" class="form-error">{{ formError }}</p>
            <button type="submit" class="primary" :disabled="busy || !currentShop">{{ busy ? 'Saving…' : 'Save settings' }}</button>
          </form>
        </article>
      </div>

      <div v-else-if="activeTab === 'devices'" class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">{{ currentShop?.name ?? 'Shop' }}</p><h2>Offline devices</h2></div>
        </div>
        <div class="callout info">Revoking stops sync immediately. A wipe request clears encrypted local sales and the PIN vault the next time the device connects.</div>
        <div v-if="!shopDevices.length" class="empty-state">No devices registered.</div>
        <div v-else class="data-table six-col">
          <div class="table-head"><span>Device</span><span>Branch</span><span>Registered</span><span>Last seen</span><span>Status</span><span></span></div>
          <div v-for="device in shopDevices" :key="device.id" class="table-row static">
            <span><b>{{ device.device_label }}</b><small>{{ device.id.slice(0, 8) }}</small></span>
            <span>{{ branchNameFor(device.branch_id) }}</span>
            <span>{{ formatDateTime(device.created_at) }}</span>
            <span>{{ device.last_seen_at ? formatDateTime(device.last_seen_at) : 'Never' }}</span>
            <span>
              <span class="status-badge" :class="device.revoked_at ? 'rejected' : device.wipe_requested_at ? 'needs_review' : 'completed'">
                {{ device.revoked_at ? 'Revoked' : device.wipe_requested_at ? 'Wipe requested' : 'Active' }}
              </span>
            </span>
            <span class="row-actions">
              <button v-if="!device.revoked_at" type="button" class="mini-button reject" @click="revoke(device.id, device.device_label)">Revoke</button>
              <button v-if="!device.wipe_requested_at" type="button" class="mini-button" @click="wipe(device.id, device.device_label)">Wipe</button>
            </span>
          </div>
        </div>
      </div>

      <div v-else-if="activeTab === 'audit'" class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">{{ auth.activeBranch?.name ?? 'Branch' }}</p><h2>Audit trail</h2></div>
          <button type="button" class="secondary small" :disabled="loadingAudit" @click="loadAudit">
            {{ loadingAudit ? 'Loading…' : 'Refresh' }}
          </button>
        </div>
        <div class="callout info">The latest 100 recorded actions for the active branch, including reviews, corrections, cash movements, and configuration changes.</div>
        <p v-if="loadingAudit" class="empty-state">Reading audit events…</p>
        <p v-else-if="!auditEvents.length" class="empty-state">No audit events recorded for this branch yet.</p>
        <div v-else class="simple-list">
          <div v-for="event in auditEvents" :key="event.id" class="simple-row">
            <div>
              <strong>{{ auditLabel(event.action) }}</strong>
              <small>{{ event.entity_type }} · {{ event.actor_name ?? 'System' }} · {{ formatDateTime(event.created_at) }}</small>
              <small v-if="auditMetadata(event.metadata)" class="audit-meta">{{ auditMetadata(event.metadata) }}</small>
            </div>
            <span class="status-badge neutral mono">{{ event.entity_id ? event.entity_id.slice(0, 8) : '—' }}</span>
          </div>
        </div>
      </div>
    </template>

    <AppModal v-if="showShop" title="Create a shop" subtitle="Shops hold branches, menu, and staff." @close="showShop = false">
      <form class="form-stack" @submit.prevent="submitShop">
        <label><span>Shop name</span><input v-model="newShopName" minlength="2" maxlength="120" required autofocus /></label>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions"><button type="button" class="secondary" @click="showShop = false">Cancel</button><button type="submit" class="primary" :disabled="busy">{{ busy ? 'Creating…' : 'Create shop' }}</button></div>
      </form>
    </AppModal>

    <AppModal v-if="showBranch" title="Create a branch" :subtitle="currentShop?.name ?? ''" @close="showBranch = false">
      <form class="form-stack" @submit.prevent="submitBranch">
        <label><span>Branch name</span><input v-model="branchName" minlength="2" maxlength="120" required autofocus /></label>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions"><button type="button" class="secondary" @click="showBranch = false">Cancel</button><button type="submit" class="primary" :disabled="busy">{{ busy ? 'Creating…' : 'Create branch' }}</button></div>
      </form>
    </AppModal>

    <AppModal v-if="showMember" title="Add a team member" subtitle="The email must already have a Benta sign-in account." @close="showMember = false">
      <form class="form-stack" @submit.prevent="submitMember">
        <label><span>Email</span><input v-model="memberEmail" type="email" required autofocus /></label>
        <label>
          <span>Role</span>
          <select v-model="memberRole">
            <option value="staff">Staff · branch only</option>
            <option v-if="canAddOwner" value="owner">Owner · whole shop</option>
            <option v-if="canAddOwner" value="super_admin">Super admin · all shops</option>
          </select>
        </label>
        <template v-if="memberRole !== 'super_admin'">
          <label>
            <span>Shop</span>
            <select v-model="memberShopId" required>
              <option v-for="shop in shops" :key="shop.id" :value="shop.id">{{ shop.name }}</option>
            </select>
          </label>
        </template>
        <label v-if="memberRole === 'staff'">
          <span>Branch</span>
          <select v-model="memberBranchId" required>
            <option v-for="branch in memberBranchOptions" :key="branch.id" :value="branch.id">{{ branch.name }}</option>
          </select>
        </label>
        <p v-if="memberRole === 'staff' && !memberBranchOptions.length" class="form-note">This shop has no branches. Create a branch first.</p>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions"><button type="button" class="secondary" @click="showMember = false">Cancel</button><button type="submit" class="primary" :disabled="busy || (memberRole !== 'super_admin' && !memberShopId) || (memberRole === 'staff' && !memberBranchId)">{{ busy ? 'Adding…' : 'Add member' }}</button></div>
      </form>
    </AppModal>

    <AppModal
      v-if="showProduct"
      :title="editingProduct ? 'Edit product' : 'New product'"
      :subtitle="currentShop?.name ?? ''"
      wide
      @close="showProduct = false"
    >
      <form class="form-stack" @submit.prevent="submitProduct">
        <div class="two-column">
          <label><span>Product name</span><input v-model="productForm.name" minlength="2" maxlength="120" required /></label>
          <label><span>Price (₱)</span><input v-model="productForm.price" inputmode="decimal" required /></label>
        </div>
        <label><span>Description</span><input v-model="productForm.description" maxlength="200" /></label>
        <div class="three-column">
          <label><span>Required options</span><input v-model.number="productForm.flavorChoices" type="number" min="0" max="10" /></label>
          <label>
            <span>Stock model</span>
            <select v-model="productForm.stockModel">
              <option value="made_to_order">Made to order</option>
              <option value="batch_produced">Batch produced</option>
            </select>
          </label>
          <label class="check-field"><input v-model="productForm.active" type="checkbox" /><span>Active</span></label>
        </div>
        <div v-if="productForm.stockModel === 'batch_produced'" class="three-column">
          <label><span>Expected yield</span><input v-model="productForm.expectedYield" inputmode="decimal" /></label>
          <label><span>Yield unit</span><input v-model="productForm.yieldUnit" maxlength="30" /></label>
          <label><span>Pieces</span><input v-model="productForm.pieces" inputmode="numeric" /></label>
        </div>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <button type="submit" class="primary" :disabled="busy">{{ busy ? 'Saving…' : 'Save product details' }}</button>
      </form>

      <template v-if="editingProduct">
        <hr class="soft-divider" />
        <div class="editor-section">
          <div class="panel-title"><div><p class="eyebrow">Flavor / option choices</p><h2>{{ editingProduct.options.length }} options</h2></div></div>
          <div class="simple-list compact-list">
            <div v-for="option in editingProduct.options" :key="option.id" class="simple-row">
              <div><strong>{{ option.name }}</strong><small>{{ option.active ? 'Active' : 'Inactive' }}</small></div>
              <button type="button" class="mini-button" @click="toggleOption(option.id, option.active, option.version)">{{ option.active ? 'Disable' : 'Enable' }}</button>
            </div>
          </div>
          <div class="inline-form">
            <input v-model="newOptionName" placeholder="New option name" maxlength="80" />
            <button type="button" class="secondary" @click="addOption">Add option</button>
          </div>
        </div>

        <div class="editor-section">
          <div class="panel-title"><div><p class="eyebrow">Recipe</p><h2>{{ editingProduct.recipe.length }} lines</h2></div></div>
          <div v-if="editingProduct.recipe.length" class="simple-list compact-list">
            <div v-for="line in editingProduct.recipe" :key="line.ingredient_id" class="simple-row">
              <div><strong>{{ line.name }}</strong><small>{{ formatQuantity(line.quantity, line.base_unit) }}</small></div>
              <button type="button" class="mini-button reject" @click="removeRecipe(line.ingredient_id)">Remove</button>
            </div>
          </div>
          <div class="two-column inline-form">
            <select v-model="recipeIngredientId">
              <option v-for="ingredient in shopIngredients" :key="ingredient.id" :value="ingredient.id">{{ ingredient.name }}</option>
            </select>
            <input v-model="recipeQuantity" inputmode="decimal" placeholder="Quantity in base unit" />
            <button type="button" class="secondary" @click="addRecipe">Add / update line</button>
          </div>
          <p class="form-note">Recipe lines make stock deduction and profit exact for this product.</p>
        </div>

        <div class="editor-section">
          <div class="panel-title"><div><p class="eyebrow">Option recipes</p><h2>Flavor costs</h2></div></div>
          <p class="form-note">Attach ingredient quantities to options so flavor costs and stock stay accurate. Add ingredients first if the shop has none.</p>
          <div class="simple-list compact-list">
            <div v-for="option in editingProduct.options" :key="option.id" class="simple-row">
              <div><strong>{{ option.name }}</strong><small>Option recipe</small></div>
              <button type="button" class="mini-button" :disabled="!shopIngredients.length" @click="openOptionRecipe(option.id)">Edit recipe</button>
            </div>
          </div>
          <div v-if="editingOption" class="callout info option-recipe-editor">
            <strong>{{ editingOption.name }} recipe line</strong>
            <div class="two-column inline-form">
              <select v-model="optionRecipeIngredientId">
                <option v-for="ingredient in shopIngredients" :key="ingredient.id" :value="ingredient.id">
                  {{ ingredient.name }} · {{ ingredient.base_unit }}
                </option>
              </select>
              <input v-model="optionRecipeQuantity" inputmode="decimal" placeholder="Quantity in base unit" />
              <button type="button" class="secondary" :disabled="optionRecipeBusy" @click="saveOptionRecipe">
                {{ optionRecipeBusy ? 'Saving…' : 'Set line' }}
              </button>
              <button type="button" class="mini-button reject" :disabled="optionRecipeBusy" @click="removeOptionRecipe">
                Remove selected line
              </button>
              <button type="button" class="text-link" @click="closeOptionRecipe">Cancel</button>
            </div>
          </div>
        </div>
      </template>
    </AppModal>

    <AppModal v-if="showIngredient" :title="editingIngredientId ? 'Edit ingredient' : 'New ingredient'" :subtitle="currentShop?.name ?? ''" @close="showIngredient = false">
      <form class="form-stack" @submit.prevent="submitIngredient">
        <label><span>Name</span><input v-model="ingredientForm.name" minlength="2" maxlength="120" required autofocus /></label>
        <div class="three-column">
          <label>
            <span>Base unit</span>
            <select v-model="ingredientForm.baseUnit"><option value="g">g (grams)</option><option value="kg">kg (kilograms)</option><option value="ml">ml (milliliters)</option><option value="L">L (liters)</option><option value="piece">piece</option></select>
          </label>
          <label><span>Low stock at</span><input v-model="ingredientForm.lowStock" inputmode="decimal" /></label>
          <label><span>Category</span><input v-model="ingredientForm.category" maxlength="60" /></label>
        </div>
        <label class="check-field"><input v-model="ingredientForm.active" type="checkbox" /><span>Active</span></label>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions"><button type="button" class="secondary" @click="showIngredient = false">Cancel</button><button type="submit" class="primary" :disabled="busy">{{ busy ? 'Saving…' : 'Save ingredient' }}</button></div>
      </form>
    </AppModal>

    <AppModal v-if="showPayment" :title="editingPaymentId ? 'Edit payment method' : 'New payment method'" :subtitle="currentShop?.name ?? ''" @close="showPayment = false">
      <form class="form-stack" @submit.prevent="submitPayment">
        <div class="two-column">
          <label><span>Name</span><input v-model="paymentForm.name" minlength="2" maxlength="60" required /></label>
          <label><span>Code</span><input v-model="paymentForm.code" minlength="2" maxlength="30" required /></label>
        </div>
        <div class="three-column">
          <label><span>Kind</span><select v-model="paymentForm.kind"><option value="cash">Cash</option><option value="gcash">GCash</option></select></label>
          <label><span>Sort order</span><input v-model.number="paymentForm.sortOrder" type="number" min="0" /></label>
          <label class="check-field"><input v-model="paymentForm.active" type="checkbox" /><span>Active</span></label>
        </div>
        <label class="check-field"><input v-model="paymentForm.requiresReference" type="checkbox" /><span>Reference number required</span></label>
        <p v-if="formError" class="form-error">{{ formError }}</p>
        <div class="dialog-actions"><button type="button" class="secondary" @click="showPayment = false">Cancel</button><button type="submit" class="primary" :disabled="busy">{{ busy ? 'Saving…' : 'Save method' }}</button></div>
      </form>
    </AppModal>
  </section>
</template>
