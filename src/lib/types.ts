export type Role = 'super_admin' | 'owner' | 'staff'
export type StockModel = 'made_to_order' | 'batch_produced'
export type PaymentKind = 'cash' | 'gcash'
export type OrderStatus = 'pending_sync' | 'completed' | 'needs_review' | 'voided' | 'refunded' | 'rejected'
export type RequestStatus = 'pending' | 'approved' | 'rejected'
export type CorrectionKind = 'void' | 'refund'
export type CashMovementKind = 'payout' | 'safe_drop'
export type ScopeType = 'branch' | 'shop' | 'group'

export interface Profile {
  id: string
  display_name: string
  created_at: string
}

export interface BusinessGroup {
  id: string
  name: string
  created_at: string
}

export interface Shop {
  id: string
  group_id: string
  name: string
  timezone: string
  config_revision: number
  active: boolean
  created_at: string
}

export interface Branch {
  id: string
  shop_id: string
  name: string
  active: boolean
  created_at: string
}

export interface Membership {
  id: string
  user_id: string
  group_id: string
  shop_id: string | null
  branch_id: string | null
  role: Role
  created_at: string
}

export interface Device {
  id: string
  branch_id: string
  user_id: string
  device_label: string
  created_at: string
  last_seen_at: string | null
  revoked_at: string | null
  wipe_requested_at: string | null
}

export interface ContextResponse {
  profile: Profile | null
  memberships: Membership[]
  groups: BusinessGroup[]
  shops: Shop[]
  branches: Branch[]
  devices: Device[]
}

export interface ShopSettings {
  tax_inclusive_enabled: boolean
  tax_rate_bps: number
  receipt_footer: string
}

export interface PaymentMethod {
  id: string
  shop_id: string
  code: string
  name: string
  kind: PaymentKind
  requires_reference: boolean
  active: boolean
  sort_order: number
  version: number
  created_at?: string
  updated_at?: string
}

export interface OptionRecipe {
  ingredient_id: string
  quantity: number
  name: string
  base_unit: string
}

export interface ProductOption {
  id: string
  name: string
  sort_order: number
  cost_centavos: number
  active?: boolean
  version?: number
  recipes?: OptionRecipe[]
}

export interface ShopFlavor {
  id: string
  shop_id: string
  name: string
  active: boolean
  sort_order: number
  version: number
  recipes?: Array<{ ingredient_id: string; ingredient_name: string; base_unit: string; quantity: number }>
  linked_product_ids?: string[]
}

export interface CatalogProduct {
  id: string
  name: string
  description: string
  price_centavos: number
  flavor_choices: number
  stock_model: StockModel
  active: boolean
  branch_available: boolean
  available: boolean
  recipe_complete: boolean
  stock_quantity: number | null
  stock_available: boolean
  expected_yield_quantity: number
  expected_yield_unit: string
  pieces: number | null
  rice_included: boolean
  options: ProductOption[]
}

export interface BranchCatalog {
  branch: Branch
  shop: Shop
  settings: ShopSettings
  payment_methods: PaymentMethod[]
  products: CatalogProduct[]
}

export interface DashboardMetrics {
  business_date: string
  scope_type: ScopeType
  scope_id: string
  orders_count: number
  gross_sales_centavos: number
  refunds_centavos: number
  revenue_centavos: number
  discounts_centavos: number
  cogs_centavos: number
  gross_profit_centavos: number
  expenses_centavos: number
  net_profit_centavos: number
  cash_sales_centavos: number
  gcash_sales_centavos: number
  inventory_value_centavos: number
  low_stock_count: number
  open_shifts_count: number
  pending_sync_count: number
  pending_approvals_count: number
  estimated_orders_count: number
  is_estimated: boolean
}

export interface CheckoutOption {
  id: string
  name: string
}

export interface CheckoutItem {
  product_id: string
  quantity: number
  selected_options: CheckoutOption[]
}

export interface SaleSummary {
  id: string
  request_id: string
  captured_at: string
  created_at: string
  offline_captured_at: string | null
  status: OrderStatus
  total_centavos: number
  subtotal_centavos: number
  discount_centavos: number
  tax_centavos: number
  tendered_centavos: number | null
  change_centavos: number | null
  review_reason: string | null
  cashier_name: string | null
  payment_method_name: string | null
  payment_method_kind: PaymentKind | null
  item_count: number
  item_names: string[]
  correction_status: RequestStatus | null
}

export interface OrderLine {
  id: string
  order_id: string
  product_id: string
  product_name: string
  unit_price_centavos: number
  quantity: number
  cost_snapshot_centavos: number
  selected_options: CheckoutOption[]
  line_subtotal_centavos: number
  stock_model: StockModel
  cost_estimated: boolean
  options: Array<{ option_id: string; name: string; unit_cost_centavos: number }>
}

export interface OrderDetail {
  order: {
    id: string
    branch_id: string
    cashier_id: string
    device_id: string | null
    request_id: string
    status: OrderStatus
    total_centavos: number
    subtotal_centavos: number
    discount_centavos: number
    discount_reason: string | null
    tax_centavos: number
    tax_rate_bps: number
    tax_inclusive: boolean
    tendered_centavos: number | null
    change_centavos: number | null
    captured_at: string
    created_at: string
    review_reason: string | null
    cashier_name: string | null
    payment_method_name: string | null
  }
  lines: OrderLine[]
  payment: {
    id: string
    order_id: string
    method: PaymentKind
    amount_centavos: number
    reference: string | null
    payment_method_id: string
    tendered_centavos: number | null
    change_centavos: number | null
    created_at: string
  } | null
  corrections: Array<{
    id: string
    order_id: string
    branch_id: string
    kind: CorrectionKind
    reason: string
    status: RequestStatus
    requested_by: string
    reviewed_by: string | null
    reviewed_at: string | null
    review_note: string | null
    refund_method: PaymentKind | null
    refund_reference: string | null
    refund_amount_centavos: number | null
    reversal_id: string | null
    created_at: string
  }>
  reversal: {
    id: string
    order_id: string
    correction_id: string
    branch_id: string
    total_centavos: number
    cost_centavos: number
    refund_method: PaymentKind
    refund_reference: string | null
    created_by: string
    created_at: string
  } | null
}

export interface Ingredient {
  id: string
  shop_id: string
  name: string
  base_unit: 'g' | 'kg' | 'ml' | 'L' | 'piece'
  category: string
  low_stock_quantity: number
  active: boolean
  version: number
  created_at: string
}

export interface IngredientBalance extends Ingredient {
  quantity: number
  average_cost_centavos: number
  value_centavos: number
  is_low: boolean
  stock_version?: number
}

export interface FinishedGood {
  product_id: string
  name: string
  stock_model: StockModel
  quantity: number
  average_cost_centavos: number
  value_centavos: number
  version: number
}

export interface InventoryMovement {
  id: string
  kind: string
  quantity_delta: number
  unit_cost_centavos: number
  created_at: string
  reference_id: string | null
  ingredient_name: string | null
  product_name: string | null
  actor_name: string | null
}

export interface InventoryResponse {
  ingredients: IngredientBalance[]
  finished_goods: FinishedGood[]
  movements: InventoryMovement[]
}

export interface ProductionBatch {
  id: string
  expected_yield: number
  actual_yield: number
  waste_quantity: number
  waste_reason: string | null
  total_cost_centavos: number
  cost_per_unit_centavos: number
  posted_at: string
  created_at: string
  product_name: string
  prepared_by_name: string | null
}

export interface CashShift {
  id: string
  branch_id: string
  cashier_id: string
  opening_cash_centavos: number
  opened_at: string
  closed_at: string | null
  counted_cash_centavos: number | null
  closed_by: string | null
  status: 'open' | 'closed'
  note: string | null
  expected_cash_centavos: number | null
  over_short_centavos: number | null
  current_expected_cash_centavos: number
  cashier_name: string | null
  cash_sales_centavos: number
  cash_movements_centavos: number
}

export interface CashRequest {
  id: string
  request_id: string
  shift_id: string
  kind: CashMovementKind
  amount_centavos: number
  reason: string
  status: RequestStatus
  created_at: string
  approved_at: string | null
  reviewed_at: string | null
  review_note: string | null
  applied_movement_id: string | null
  requested_by_name: string | null
}

export interface Correction {
  id: string
  order_id: string
  kind: CorrectionKind
  reason: string
  status: RequestStatus
  created_at: string
  reviewed_at: string | null
  review_note: string | null
  refund_method: PaymentKind | null
  refund_reference: string | null
  refund_amount_centavos: number | null
  reversal_id: string | null
  order_total_centavos: number
  requested_by_name: string | null
}

export interface Expense {
  id: string
  category: string
  description: string
  amount_centavos: number
  delivery_fee_centavos: number
  paid_from_cash: boolean
  cash_movement_id: string | null
  spent_at: string
  created_at: string
  created_by_name: string | null
}

export interface RestockItem {
  ingredient_id: string
  ingredient_name: string
  quantity: number
  unit_cost_centavos: number
}

export interface Restock {
  id: string
  branch_id: string
  supplier: string | null
  note: string | null
  total_cost_centavos: number
  delivery_fee_centavos: number
  paid_from_cash: boolean
  cash_movement_id: string | null
  created_at: string
  created_by_name: string | null
  items: RestockItem[]
}

export interface PurchaseRow {
  id: string
  type: 'restock' | 'expense'
  purchase_date: string
  supplier_category: string
  description: string
  items: string
  base_cost_centavos: number
  delivery_fee_centavos: number
  total_deducted_centavos: number
  paid_from_cash: boolean
  cash_movement_id: string | null
  created_by_name: string | null
}

export interface AuditEvent {
  id: number
  action: string
  entity_type: string
  entity_id: string | null
  metadata: Record<string, unknown>
  created_at: string
  actor_name: string | null
}

export interface ReportResponse {
  from_date: string
  to_date: string
  scope_type: ScopeType
  scope_id: string
  sales: {
    orders_count: number
    gross_sales_centavos: number
    refunds_centavos: number
    revenue_centavos: number
    discounts_centavos: number
    cash_net_centavos: number
    gcash_centavos: number
    estimated_orders_count: number
  }
  profit: {
    cogs_centavos: number
    gross_profit_centavos: number
    expenses_centavos: number
    net_profit_centavos: number
    food_cost_bps: number
    is_estimated: boolean
  }
  inventory: { value_centavos: number; low_stock_count: number }
  cash: {
    shifts_count: number
    expected_cash_centavos: number
    counted_cash_centavos: number
    over_short_centavos: number
    payouts_centavos: number
    safe_drops_centavos: number
    cash_refunds_centavos: number
  }
  production: {
    batches_count: number
    expected_yield: number
    actual_yield: number
    waste_quantity: number
    total_cost_centavos: number
  }
  corrections: { requested_count: number; approved_count: number; refunded_centavos: number }
  popular_products: Array<{ product_name: string; quantity: number; sales_centavos: number }>
  popular_options: Array<{ option_name: string; quantity: number }>
  cashiers: Array<{ cashier_name: string | null; orders_count: number; sales_centavos: number }>
}

export interface AdminData {
  group: BusinessGroup
  shops: Shop[]
  branches: Branch[]
  members: Array<{
    id: string
    user_id: string
    role: Role
    shop_id: string | null
    branch_id: string | null
    display_name: string | null
    email: string | null
    created_at: string
  }>
  devices: Device[]
  products: Array<{
    id: string
    shop_id: string
    name: string
    description: string
    price_centavos: number
    flavor_choices: number
    stock_model: StockModel
    expected_yield_quantity: number
    expected_yield_unit: string
    pieces: number | null
    rice_included: boolean
    active: boolean
    version: number
    options: Array<{ id: string; name: string; active: boolean; sort_order: number; version: number; recipes: Array<{ ingredient_id: string; quantity: number; name: string; base_unit: string }> }>
    recipe: Array<{ ingredient_id: string; quantity: number; name: string; base_unit: string }>
  }>
  ingredients: Ingredient[]
  payment_methods: PaymentMethod[]
  settings: Array<ShopSettings & { shop_id: string; version: number }>
}

export interface PendingReview {
  id: string
  total_centavos: number
  created_at: string
  review_reason: string | null
  request_id: string
  device_id: string | null
  cashier_name: string | null
  item_names: string[]
}

export interface CartLine {
  product: CatalogProduct
  quantity: number
  options: ProductOption[]
}

export interface OfflineCheckout {
  id: string
  captured_at: string
  branch_id: string
  device_id: string
  payment_method_id: string
  payment_reference: string | null
  items: CheckoutItem[]
  discount_centavos: number
  discount_reason: string | null
  tendered_centavos: number | null
  config_revision: number
  local_sequence: number
  total_centavos: number
  order_label: string
}
