import { describe, expect, it } from 'vitest'
import { wingProducts } from './catalog'
import { cartHasRequiredFlavors } from './pos'

describe('POS flavor requirements', () => {
  it('requires the configured number of flavors per item', () => {
    expect(cartHasRequiredFlavors([{ product: wingProducts[0], quantity: 1, flavors: ['Buffalo'] }])).toBe(true)
    expect(cartHasRequiredFlavors([{ product: wingProducts[2], quantity: 1, flavors: ['Buffalo'] }])).toBe(false)
    expect(cartHasRequiredFlavors([{ product: wingProducts[2], quantity: 1, flavors: ['Buffalo', 'Honey Soy'] }])).toBe(true)
  })
})
