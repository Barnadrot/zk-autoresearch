# A1: MulAccByElement Port — Ready-to-Apply Change

## File: `prover/crypto/vortex/prover_common.go`

## Summary
Port the MulAccByElement optimization from `limitless-onthefly` branch.
Replaces ext×ext multiply (9 base field muls per element) with ext×base
multiply-accumulate (4 muls per element, AVX-512 accelerated via
`mulAccByElement_avx512` in gnark-crypto).

## Exact changes needed

### Change 1: Update comment (line 23-27 → line 23)
Replace the old comment block with:
```
// LinearCombination computes ∑ᵢ (randomCoin^i) * v[i] for each position.
```

### Change 2: Add baseScratch allocation (after line 39)
Add `baseScratch := make(field.Vector, chunkLen)` alongside existing scratch allocations.
Also extract `chunkLen := stop - start` for clarity.

### Change 3: Replace Regular vector case (lines 54-58)
Replace the lift-then-multiply path with direct MulAccByElement:
```go
case *smartvectors.Regular:
    copy(baseScratch, field.Vector((*_svt)[start:stop]))
    localLinComb.MulAccByElement(baseScratch, &x)
    x.Mul(&x, &randomCoin)
    continue
```

## Full file after change
```go
package vortex

import (
	"github.com/consensys/linea-monorepo/prover/maths/common/smartvectors"
	"github.com/consensys/linea-monorepo/prover/maths/common/vectorext"
	"github.com/consensys/linea-monorepo/prover/maths/field"
	"github.com/consensys/linea-monorepo/prover/maths/field/fext"
	"github.com/consensys/linea-monorepo/prover/utils"
	"github.com/consensys/linea-monorepo/prover/utils/parallel"
)

// OpeningProof represents an opening proof for a Vortex commitment
type OpeningProof struct {

	// Columns [i][j][k] returns the k-th entry
	// of the j-th selected column of the i-th commitment
	Columns [][][]field.Element

	// Linear combination of the Reed-Solomon encoded polynomials to open.
	LinearCombination smartvectors.SmartVector
}

// LinearCombination computes ∑ᵢ (randomCoin^i) * v[i] for each position.
func LinearCombination(proof *OpeningProof, v []smartvectors.SmartVector, randomCoin fext.Element) {

	if len(v) == 0 {
		utils.Panic("attempted to open an empty witness")
	}

	n := v[0].Len()
	linComb := make([]fext.Element, n)
	parallel.Execute(len(linComb), func(start, stop int) {
		chunkLen := stop - start

		x := fext.One()
		scratch := make(vectorext.Vector, chunkLen)
		baseScratch := make(field.Vector, chunkLen)
		localLinComb := make(vectorext.Vector, chunkLen)
		for i := range v {
			_sv := v[i]
			switch _svt := _sv.(type) {
			case *smartvectors.Constant:
				cst := _svt.GetExt(0)
				cst.Mul(&cst, &x)
				for j := range localLinComb {
					localLinComb[j].Add(&localLinComb[j], &cst)
				}
				x.Mul(&x, &randomCoin)
				continue
			case *smartvectors.Regular:
				// Fast path: use ext×base multiply (4 muls) instead of
				// lifting to ext then ext×ext (9 muls).
				copy(baseScratch, field.Vector((*_svt)[start:stop]))
				localLinComb.MulAccByElement(baseScratch, &x)
				x.Mul(&x, &randomCoin)
				continue
			default:
				sv := _svt.SubVector(start, stop)
				sv.WriteInSliceExt(scratch)
			}
			scratch.ScalarMul(scratch, &x)
			localLinComb.Add(localLinComb, scratch)
			x.Mul(&x, &randomCoin)

		}
		copy(linComb[start:stop], localLinComb)
	})

	proof.LinearCombination = smartvectors.NewRegularExt(linComb)
}
```

## AVX-512 alignment note (FLAG 6)
`MulAccByElement` dispatches to AVX-512 when `len(vector) % 4 == 0`.
`parallel.Execute` creates chunks of `n / GOMAXPROCS` with leftover distributed
to first tasks. For power-of-2 vector lengths on typical core counts (4, 8, 16),
chunks are multiples of 4. Edge cases:
- n=1024, 4 cores → chunks of 256 ✓
- n=1024, 8 cores → chunks of 128 ✓
- n=8192, 4 cores → chunks of 2048 ✓
- n=15 (tiny test) → single chunk of 15 → scalar fallback (acceptable)

## Correctness verification
The `continue` in the Regular case skips the `scratch.ScalarMul` + `localLinComb.Add`
path entirely. `MulAccByElement` computes `localLinComb[i] += x * baseScratch[i]`
which is mathematically identical to:
  1. SetFromBase each element into scratch (lift to ext)
  2. scratch.ScalarMul(scratch, &x) (ext × ext multiply)
  3. localLinComb.Add(localLinComb, scratch) (accumulate)

The difference: MulAccByElement uses ext×base (4 muls) vs ext×ext (9 muls),
and does multiply+accumulate in one call vs two separate operations.
