import { describe, expect, it } from 'vitest'
import { formatDate, formatQuantity, manilaDate } from './datetime'

describe('Manila business dates', () => {
  it('rolls the business date across the UTC boundary', () => {
    expect(manilaDate(new Date('2026-10-24T15:59:00Z'))).toBe('2026-10-24')
    expect(manilaDate(new Date('2026-10-24T16:00:00Z'))).toBe('2026-10-25')
  })

  it('formats invalid dates safely', () => {
    expect(formatDate('not-a-date')).toBe('—')
  })

  it('formats quantities for ingredient units', () => {
    expect(formatQuantity(1.23456, 'g')).toBe('1.235 g')
    expect(formatQuantity(2, 'piece')).toBe('2 piece')
  })
})
