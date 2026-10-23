import { describe, expect, it } from 'vitest'
import { calculateChange, pesosToCentavos } from './money'

describe('money rules', () => {
  it('keeps peso amounts in integer centavos', () => {
    expect(pesosToCentavos(89)).toBe(8900)
    expect(pesosToCentavos(89.995)).toBe(9000)
  })

  it('never returns negative cash change', () => {
    expect(calculateChange(10000, 8900)).toBe(1100)
    expect(calculateChange(5000, 8900)).toBe(0)
  })
})
