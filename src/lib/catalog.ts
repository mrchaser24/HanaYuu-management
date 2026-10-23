import type { Product } from './types'
import { pesosToCentavos } from './money'

export const wingProducts: Product[] = [
  { id: 'solo-2', name: 'Solo 2-piece meal', priceCentavos: pesosToCentavos(89), description: '2 wings + 1 Java rice', flavorChoices: 1, stockModel: 'made_to_order', available: true },
  { id: 'solo-3', name: 'Solo 3-piece meal', priceCentavos: pesosToCentavos(119), description: '3 wings + 1 Java rice', flavorChoices: 1, stockModel: 'made_to_order', available: true },
  { id: 'wings-6', name: '6-piece wings', priceCentavos: pesosToCentavos(189), description: '6 wingette/drummette', flavorChoices: 2, stockModel: 'made_to_order', available: true },
  { id: 'wings-12', name: '12-piece wings', priceCentavos: pesosToCentavos(349), description: '12 wingette/drummette', flavorChoices: 3, stockModel: 'made_to_order', available: true },
  { id: 'wings-20', name: '20-piece wings', priceCentavos: pesosToCentavos(549), description: '20 wingette/drummette', flavorChoices: 4, stockModel: 'made_to_order', available: true },
  { id: 'wings-30', name: '30-piece wings', priceCentavos: pesosToCentavos(799), description: '30 wingette/drummette', flavorChoices: 5, stockModel: 'made_to_order', available: true },
]

export const defaultFlavors = ['Buffalo', 'Garlic Parmesan', 'Honey Soy', 'Korean BBQ', 'Salted Egg', 'Spicy Yangnyeom']
