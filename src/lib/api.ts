import { supabase } from './supabase'
import type {
  AdminData,
  AuditEvent,
  BranchCatalog,
  CashMovementKind,
  CashRequest,
  CashShift,
  CheckoutItem,
  ContextResponse,
  Correction,
  CorrectionKind,
  DashboardMetrics,
  Expense,
  InventoryResponse,
  OfflineCheckout,
  OrderDetail,
  PaymentKind,
  PendingReview,
  ProductionBatch,
  Profile,
  ReportResponse,
  Role,
  SaleSummary,
  ScopeType,
  StockModel,
} from './types'

type RpcArgs = Record<string, unknown>

export class ApiError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ApiError'
  }
}

async function rpc<T>(name: string, args: RpcArgs = {}): Promise<T> {
  if (!supabase) throw new ApiError('Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.')
  const { data, error } = await supabase.rpc(name, args)
  if (error) throw new ApiError(error.message)
  return data as T
}

export async function ensureProfile(displayName: string): Promise<Profile> {
  if (!supabase) throw new ApiError('Supabase is not configured.')
  const { data: userData, error: userError } = await supabase.auth.getUser()
  if (userError || !userData.user) throw new ApiError(userError?.message ?? 'Authentication required.')
  const { data, error } = await supabase
    .from('profiles')
    .upsert({ id: userData.user.id, display_name: displayName.trim().slice(0, 100) }, { onConflict: 'id' })
    .select('id, display_name, created_at')
    .single()
  if (error) throw new ApiError(error.message)
  return data as Profile
}

export function getMyContext(): Promise<ContextResponse> {
  return rpc<ContextResponse>('get_my_context')
}

export function getBranchCatalog(branchId: string): Promise<BranchCatalog> {
  return rpc<BranchCatalog>('get_branch_catalog', { p_branch_id: branchId })
}

export function getDashboardMetrics(scopeType: ScopeType, scopeId: string, date?: string): Promise<DashboardMetrics> {
  return rpc<DashboardMetrics>('get_dashboard_metrics', {
    p_scope_type: scopeType,
    p_scope_id: scopeId,
    p_date: date ?? null,
  })
}

export function getSalesHistory(
  branchId: string,
  from?: string,
  to?: string,
  limit = 100,
  offset = 0,
): Promise<SaleSummary[]> {
  return rpc<SaleSummary[]>('get_sales_history', {
    p_branch_id: branchId,
    p_from: from ?? null,
    p_to: to ?? null,
    p_limit: limit,
    p_offset: offset,
  })
}

export function getOrderDetail(orderId: string): Promise<OrderDetail> {
  return rpc<OrderDetail>('get_order_detail', { p_order_id: orderId })
}

export function recordCheckout(input: {
  branchId: string
  deviceId: string | null
  requestId: string
  paymentMethodId: string
  paymentReference: string | null
  items: CheckoutItem[]
  discountCentavos: number
  discountReason: string | null
  tenderedCentavos: number | null
  capturedAt: string
  configRevision: number | null
}): Promise<string> {
  return rpc<string>('record_checkout', {
    p_branch_id: input.branchId,
    p_device_id: input.deviceId,
    p_request_id: input.requestId,
    p_payment_method_id: input.paymentMethodId,
    p_payment_reference: input.paymentReference,
    p_items: input.items,
    p_discount_centavos: input.discountCentavos,
    p_discount_reason: input.discountReason,
    p_tendered_centavos: input.tenderedCentavos,
    p_captured_at: input.capturedAt,
    p_config_revision: input.configRevision,
  })
}

export function syncOfflineCheckout(record: OfflineCheckout): Promise<string | null> {
  return rpc<string | null>('sync_offline_checkout', {
    p_branch_id: record.branch_id,
    p_device_id: record.device_id,
    p_request_id: record.id,
    p_payment_method_id: record.payment_method_id,
    p_payment_reference: record.payment_reference,
    p_items: record.items,
    p_discount_centavos: record.discount_centavos,
    p_discount_reason: record.discount_reason,
    p_tendered_centavos: record.tendered_centavos,
    p_captured_at: record.captured_at,
    p_config_revision: record.config_revision,
    p_local_sequence: record.local_sequence,
  })
}

export function getInventory(branchId: string): Promise<InventoryResponse> {
  return rpc<InventoryResponse>('get_inventory', { p_branch_id: branchId })
}

export function recordRestock(input: {
  branchId: string
  requestId: string
  supplier: string
  note: string
  items: Array<{ ingredient_id: string; quantity: number; unit_cost_centavos: number }>
}): Promise<string> {
  return rpc<string>('record_restock', {
    p_branch_id: input.branchId,
    p_request_id: input.requestId,
    p_supplier: input.supplier,
    p_note: input.note,
    p_items: input.items,
  })
}

export function getProductionBatches(branchId: string, limit = 50): Promise<ProductionBatch[]> {
  return rpc<ProductionBatch[]>('get_production_batches', { p_branch_id: branchId, p_limit: limit })
}

export function postProductionBatch(input: {
  branchId: string
  productId: string
  requestId: string
  actualYield: number
  wasteQuantity: number
  wasteReason: string
}): Promise<string> {
  return rpc<string>('post_production_batch', {
    p_branch_id: input.branchId,
    p_product_id: input.productId,
    p_request_id: input.requestId,
    p_actual_yield: input.actualYield,
    p_waste_quantity: input.wasteQuantity,
    p_waste_reason: input.wasteReason,
  })
}

export function getCashShifts(branchId: string, limit = 50): Promise<CashShift[]> {
  return rpc<CashShift[]>('get_cash_shifts', { p_branch_id: branchId, p_limit: limit })
}

export function openShift(branchId: string, openingCashCentavos: number): Promise<string> {
  return rpc<string>('open_shift', { p_branch_id: branchId, p_opening_cash_centavos: openingCashCentavos })
}

export function closeShift(shiftId: string, countedCashCentavos: number, note: string): Promise<{
  shift_id: string
  expected_cash_centavos: number
  counted_cash_centavos: number
  over_short_centavos: number
  closed_at: string
}> {
  return rpc('close_shift', {
    p_shift_id: shiftId,
    p_counted_cash_centavos: countedCashCentavos,
    p_note: note,
  })
}

export function getCashRequests(branchId: string, status?: string): Promise<CashRequest[]> {
  return rpc<CashRequest[]>('get_cash_requests', { p_branch_id: branchId, p_status: status ?? null })
}

export function requestCashMovement(input: {
  shiftId: string
  requestId: string
  kind: CashMovementKind
  amountCentavos: number
  reason: string
}): Promise<string> {
  return rpc<string>('request_cash_movement', {
    p_shift_id: input.shiftId,
    p_request_id: input.requestId,
    p_kind: input.kind,
    p_amount_centavos: input.amountCentavos,
    p_reason: input.reason,
  })
}

export function reviewCashMovement(requestId: string, approve: boolean, note: string): Promise<string | null> {
  return rpc<string | null>('review_cash_movement', {
    p_request_id: requestId,
    p_approve: approve,
    p_note: note,
  })
}

export function getCorrections(branchId: string, status?: string): Promise<Correction[]> {
  return rpc<Correction[]>('get_corrections', { p_branch_id: branchId, p_status: status ?? null })
}

export function requestCorrection(orderId: string, kind: CorrectionKind, reason: string): Promise<string> {
  return rpc<string>('request_correction', { p_order_id: orderId, p_kind: kind, p_reason: reason })
}

export function reviewCorrection(input: {
  correctionId: string
  approve: boolean
  note: string
  refundMethod?: PaymentKind | null
  refundReference?: string | null
}): Promise<string | null> {
  return rpc<string | null>('review_correction', {
    p_correction_id: input.correctionId,
    p_approve: input.approve,
    p_note: input.note,
    p_refund_method: input.refundMethod ?? null,
    p_refund_reference: input.refundReference ?? null,
  })
}

export function getExpenses(branchId: string, from?: string, to?: string): Promise<Expense[]> {
  return rpc<Expense[]>('get_expenses', { p_branch_id: branchId, p_from: from ?? null, p_to: to ?? null })
}

export function getAuditEvents(branchId: string, limit = 100): Promise<AuditEvent[]> {
  return rpc<AuditEvent[]>('get_audit_events', { p_branch_id: branchId, p_limit: limit })
}

export function recordExpense(input: {
  branchId: string
  category: string
  description: string
  amountCentavos: number
  paidFromCash: boolean
  cashMovementId: string | null
  spentAt: string
}): Promise<string> {
  return rpc<string>('record_expense', {
    p_branch_id: input.branchId,
    p_category: input.category,
    p_description: input.description,
    p_amount_centavos: input.amountCentavos,
    p_paid_from_cash: input.paidFromCash,
    p_cash_movement_id: input.cashMovementId,
    p_spent_at: input.spentAt,
  })
}

export function getReports(
  scopeType: ScopeType,
  scopeId: string,
  from?: string,
  to?: string,
): Promise<ReportResponse> {
  return rpc<ReportResponse>('get_reports', {
    p_scope_type: scopeType,
    p_scope_id: scopeId,
    p_from: from ?? null,
    p_to: to ?? null,
  })
}

export function getAdminData(groupId: string): Promise<AdminData> {
  return rpc<AdminData>('get_admin_data', { p_group_id: groupId })
}

export function getPendingReviews(branchId: string): Promise<PendingReview[]> {
  return rpc<PendingReview[]>('get_pending_reviews', { p_branch_id: branchId })
}

export function reviewReviewOrder(orderId: string, action: 'approve' | 'void' | 'reject', reason?: string): Promise<string> {
  return rpc<string>('review_review_order', { p_order_id: orderId, p_action: action, p_reason: reason ?? null })
}

export function registerDevice(branchId: string, label: string): Promise<string> {
  return rpc<string>('register_device', { p_branch_id: branchId, p_label: label })
}

export function revokeDevice(deviceId: string, reason: string): Promise<void> {
  return rpc<void>('revoke_device', { p_device_id: deviceId, p_reason: reason })
}

export function requestDeviceWipe(deviceId: string): Promise<void> {
  return rpc<void>('request_device_wipe', { p_device_id: deviceId })
}

export function createShop(groupId: string, name: string): Promise<string> {
  return rpc<string>('create_shop', { p_group_id: groupId, p_name: name })
}

export function createBranch(shopId: string, name: string): Promise<string> {
  return rpc<string>('create_branch', { p_shop_id: shopId, p_name: name })
}

export function addMembership(input: {
  email: string
  role: Role
  groupId: string
  shopId: string | null
  branchId: string | null
}): Promise<string> {
  return rpc<string>('add_membership', {
    p_email: input.email,
    p_role: input.role,
    p_group_id: input.groupId,
    p_shop_id: input.shopId,
    p_branch_id: input.branchId,
  })
}

export function removeMembership(membershipId: string): Promise<void> {
  return rpc<void>('remove_membership', { p_membership_id: membershipId })
}

export function upsertProduct(input: {
  shopId: string
  productId: string | null
  name: string
  description: string
  priceCentavos: number
  flavorChoices: number
  stockModel: StockModel
  expectedYieldQuantity: number
  expectedYieldUnit: string
  pieces: number | null
  riceIncluded: boolean
  active: boolean
  version: number | null
}): Promise<string> {
  return rpc<string>('upsert_product', {
    p_shop_id: input.shopId,
    p_product_id: input.productId,
    p_name: input.name,
    p_description: input.description,
    p_price_centavos: input.priceCentavos,
    p_flavor_choices: input.flavorChoices,
    p_stock_model: input.stockModel,
    p_expected_yield_quantity: input.expectedYieldQuantity,
    p_expected_yield_unit: input.expectedYieldUnit,
    p_pieces: input.pieces,
    p_rice_included: input.riceIncluded,
    p_active: input.active,
    p_version: input.version,
  })
}

export function upsertProductOption(input: {
  productId: string
  optionId: string | null
  name: string
  active: boolean
  sortOrder: number
  version: number | null
}): Promise<string> {
  return rpc<string>('upsert_product_option', {
    p_product_id: input.productId,
    p_option_id: input.optionId,
    p_name: input.name,
    p_active: input.active,
    p_sort_order: input.sortOrder,
    p_version: input.version,
  })
}

export function setBranchProductAvailability(
  branchId: string,
  productId: string,
  available: boolean,
  version: number | null,
): Promise<void> {
  return rpc<void>('set_branch_product_availability', {
    p_branch_id: branchId,
    p_product_id: productId,
    p_available: available,
    p_version: version,
  })
}

export function upsertIngredient(input: {
  shopId: string
  ingredientId: string | null
  name: string
  baseUnit: 'g' | 'ml' | 'piece'
  lowStockQuantity: number
  category: string
  active: boolean
  version: number | null
}): Promise<string> {
  return rpc<string>('upsert_ingredient', {
    p_shop_id: input.shopId,
    p_ingredient_id: input.ingredientId,
    p_name: input.name,
    p_base_unit: input.baseUnit,
    p_low_stock_quantity: input.lowStockQuantity,
    p_category: input.category,
    p_active: input.active,
    p_version: input.version,
  })
}

export function upsertRecipeComponent(productId: string, ingredientId: string, quantity: number): Promise<string> {
  return rpc<string>('upsert_recipe_component', {
    p_product_id: productId,
    p_ingredient_id: ingredientId,
    p_quantity: quantity,
  })
}

export function deleteRecipeComponent(productId: string, ingredientId: string): Promise<void> {
  return rpc<void>('delete_recipe_component', { p_product_id: productId, p_ingredient_id: ingredientId })
}

export function upsertOptionRecipe(optionId: string, ingredientId: string, quantity: number): Promise<string> {
  return rpc<string>('upsert_option_recipe', {
    p_option_id: optionId,
    p_ingredient_id: ingredientId,
    p_quantity: quantity,
  })
}

export function deleteOptionRecipe(optionId: string, ingredientId: string): Promise<void> {
  return rpc<void>('delete_option_recipe', { p_option_id: optionId, p_ingredient_id: ingredientId })
}

export function upsertPaymentMethod(input: {
  shopId: string
  methodId: string | null
  code: string
  name: string
  kind: PaymentKind
  requiresReference: boolean
  active: boolean
  sortOrder: number
  version: number | null
}): Promise<string> {
  return rpc<string>('upsert_payment_method', {
    p_shop_id: input.shopId,
    p_method_id: input.methodId,
    p_code: input.code,
    p_name: input.name,
    p_kind: input.kind,
    p_requires_reference: input.requiresReference,
    p_active: input.active,
    p_sort_order: input.sortOrder,
    p_version: input.version,
  })
}

export function updateShopSettings(input: {
  shopId: string
  taxInclusiveEnabled: boolean
  taxRateBps: number
  receiptFooter: string
  version: number | null
}): Promise<void> {
  return rpc<void>('update_shop_settings', {
    p_shop_id: input.shopId,
    p_tax_inclusive_enabled: input.taxInclusiveEnabled,
    p_tax_rate_bps: input.taxRateBps,
    p_receipt_footer: input.receiptFooter,
    p_version: input.version,
  })
}

export function updateShopName(input: {
  shopId: string, 
  name: string, 
  version: number | null
}): Promise<void> {
  return rpc<void>('update_shop_name', {
    p_shop_id: input.shopId,
    p_name: input.name,
    p_version: input.version,
  })
}
