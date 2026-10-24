import { beforeEach, describe, expect, it } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useCartStore } from './cart'
import type { CatalogProduct, ProductOption } from '../lib/types'

const option: ProductOption = {
  id: 'option-1',
  name: 'Classic',
  active: true,
  sort_order: 1,
  cost_centavos: 0,
  version: 1,
}

function product(overrides: Partial<CatalogProduct> = {}): CatalogProduct {
  return {
    id: 'product-1',
    name: 'Wings',
    description: '',
    price_centavos: 8900,
    flavor_choices: 0,
    stock_model: 'made_to_order',
    active: true,
    branch_available: true,
    available: true,
    recipe_complete: true,
    stock_quantity: null,
    stock_available: true,
    expected_yield_quantity: 1,
    expected_yield_unit: 'serving',
    pieces: null,
    rice_included: false,
    options: [],
    ...overrides,
  }
}

describe('cart rules', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('blocks unavailable and out-of-stock products', () => {
    const cart = useCartStore()
    expect(cart.addProduct(product({ available: false }))).toBe(false)
    expect(cart.addProduct(product({ stock_available: false }))).toBe(false)
    expect(cart.lines).toHaveLength(0)
  })

  it('adds and increments products', () => {
    const cart = useCartStore()
    expect(cart.addProduct(product())).toBe(true)
    expect(cart.addProduct(product())).toBe(true)
    expect(cart.cartCount).toBe(2)
    expect(cart.subtotalCentavos).toBe(17800)
  })

  it('requires the configured number of options', () => {
    const cart = useCartStore()
    const wings = product({ flavor_choices: 1, options: [option] })
    cart.addProduct(wings)
    expect(cart.ready).toBe(false)
    cart.toggleOption(wings.id, option)
    expect(cart.ready).toBe(true)
    expect(cart.payload()[0]?.selected_options).toEqual([{ id: option.id, name: option.name }])
  })

  it('requires quantity * flavor_choices for multi-quantity lines', () => {
    const cart = useCartStore()
    const wings = product({ flavor_choices: 2, options: [option] })
    cart.addProduct(wings)
    cart.setQuantity(wings.id, 2)
    expect(cart.ready).toBe(false)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    expect(cart.ready).toBe(false)
    const option2: ProductOption = { ...option, id: 'option-2', name: 'BBQ' }
    cart.toggleOption(wings.id, option2)
    cart.toggleOption(wings.id, option2)
    expect(cart.ready).toBe(true)
    expect(cart.invalidLines).toHaveLength(0)
  })

  it('allows selecting the same flavor multiple times', () => {
    const cart = useCartStore()
    const wings = product({ flavor_choices: 2, options: [option] })
    cart.addProduct(wings)
    cart.setQuantity(wings.id, 2)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    expect(cart.ready).toBe(true)
    const payload = cart.payload()[0]?.selected_options ?? []
    expect(payload).toHaveLength(4)
    expect(payload.filter((o) => o.id === option.id)).toHaveLength(4)
  })

  it('cannot add more flavors once the cap is reached', () => {
    const cart = useCartStore()
    const wings = product({ flavor_choices: 2, options: [option] })
    cart.addProduct(wings)
    cart.setQuantity(wings.id, 2)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    expect(cart.ready).toBe(true)
    cart.toggleOption(wings.id, option)
    expect(cart.lines[0]?.options).toHaveLength(4)
  })

  it('reducing quantity trims excess flavor selections', () => {
    const cart = useCartStore()
    const wings = product({ flavor_choices: 2, options: [option] })
    cart.addProduct(wings)
    cart.setQuantity(wings.id, 2)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    cart.toggleOption(wings.id, option)
    expect(cart.ready).toBe(true)
    cart.setQuantity(wings.id, 1)
    expect(cart.ready).toBe(true)
    expect(cart.lines[0]?.options).toHaveLength(2)
  })

  it('clamps discounts and requires a reason', () => {
    const cart = useCartStore()
    cart.addProduct(product())
    cart.setDiscount(9900, '  ')
    expect(cart.discountCentavos).toBe(8900)
    expect(cart.totalCentavos).toBe(0)
    expect(cart.ready).toBe(false)
    cart.setDiscount(1000, 'Staff meal')
    expect(cart.totalCentavos).toBe(7900)
    expect(cart.ready).toBe(true)
  })

  it('removes lines when quantity reaches zero', () => {
    const cart = useCartStore()
    cart.addProduct(product())
    cart.setQuantity('product-1', 3)
    expect(cart.cartCount).toBe(3)
    cart.setQuantity('product-1', 0)
    expect(cart.lines).toHaveLength(0)
  })
})
