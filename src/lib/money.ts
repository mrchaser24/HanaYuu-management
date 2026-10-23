export const formatPeso = (centavos: number): string =>
  new Intl.NumberFormat('en-PH', {
    style: 'currency',
    currency: 'PHP',
    minimumFractionDigits: 2,
  }).format(centavos / 100)

export const pesosToCentavos = (value: number): number => Math.round(value * 100)

export const calculateChange = (tenderedCentavos: number, totalCentavos: number): number =>
  Math.max(0, tenderedCentavos - totalCentavos)
