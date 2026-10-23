const pesoFormatter = new Intl.NumberFormat('en-PH', {
  style: 'currency',
  currency: 'PHP',
  minimumFractionDigits: 2,
})

export function pesosToCentavos(value: number): number {
  if (!Number.isFinite(value)) return 0
  return Math.round(value * 100)
}

export function centavosToPesos(value: number): number {
  return value / 100
}

export function parsePesoInput(value: string): number {
  const cleaned = value.replace(/[^0-9.]/g, '')
  const parts = cleaned.split('.')
  const normalized = parts.length > 1 ? `${parts[0]}.${parts.slice(1).join('')}` : cleaned
  return pesosToCentavos(Number(normalized) || 0)
}

export function formatPeso(centavos: number): string {
  return pesoFormatter.format(centavos / 100)
}

export function formatPesoInput(centavos: number): string {
  return (centavos / 100).toFixed(2)
}

export function calculateChange(tenderedCentavos: number, totalCentavos: number): number {
  return Math.max(tenderedCentavos - totalCentavos, 0)
}

export function formatPercentFromBasisPoints(basisPoints: number): string {
  return `${(basisPoints / 100).toFixed(basisPoints % 100 === 0 ? 0 : 1)}%`
}
