export type Role = 'super_admin' | 'owner' | 'staff'
export type PaymentMethod = 'cash' | 'gcash'
export type StockModel = 'made_to_order' | 'batch_produced'

export interface Product {
  id: string
  name: string
  priceCentavos: number
  description: string
  flavorChoices: number
  stockModel: StockModel
  available: boolean
}

export interface CartLine {
  product: Product
  quantity: number
  flavors: string[]
}

export interface SaleRecord {
  id: string
  orderNumber: string
  createdAt: string
  cashierName: string
  totalCentavos: number
  paymentMethod: PaymentMethod
  status: 'completed' | 'pending_sync' | 'needs_review'
  items: CartLine[]
}

export interface DashboardMetrics {
  todaySalesCentavos: number
  todayProfitCentavos: number
  inventoryValueCentavos: number
  pendingSyncCount: number
}
