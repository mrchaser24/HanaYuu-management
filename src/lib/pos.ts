import type { CartLine } from './types'

export const cartHasRequiredFlavors = (cart: CartLine[]): boolean =>
  cart.length > 0 && cart.every((line) => line.flavors.length === line.product.flavorChoices)
