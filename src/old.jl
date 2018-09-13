function canomove(bond::Bond, nstep, tol=ZERO_REF, maxN=Inf)
    nsite = mps |> length
    llink_axis, rlink_axis = mps |> llink_axis, mps |> rlink_axis
    # check and prepair data
    if mps.l + nstep > nsite || mps.l + nstep < 0
        throw(ArgumentError("Illegal Move!"))
    end
    # prepair the tensor, Get A,B matrix
    mps.l = (mps.l + 1) if right else (mps.l - 1)
    if right:
        A = mps.ML[mps.l - 1].mul_axis(mps.S, llink_axis)
        if mps.l == nsite:
            S = sqrt((A**2).sum())
            mps.S = array([S])
            mps.ML[-1] = A / S
            return 1 - acc
        B = mps.ML[mps.l]
    else:
        B = mps.ML[mps.l].mul_axis(mps.S, rlink_axis)
        if mps.l == 0:
            S = sqrt((B**2).sum())
            mps.S = array([S])
            mps.ML[0] = B / S
            return 1 - acc
        A = mps.ML[mps.l - 1]
    end
end
 
"""
Move l-index by one with specific direction.

Args:
    nstep (int): move l nstep towards right.
    tol (float): the tolerence for compression.
    maxN (int): the maximum dimension.

Returns:
    float, approximate truncation error.
"""
function canonical(bond::Bond, rightcan::Bool, tol=1e-15, maxN=Inf)
    # contract AB,
    D = length(bond.leg1)
    A, B = bond.leg1.ts, bond.leg2.ts
    AB = tensorproduct(A, (bond.leg1.axis,), B, (bond.leg2.axis,))
    U, S, V = svd(reshape(AB, length(A) ÷ D, length(B) ÷ D))

    # truncation
    if maxN < length(S)
        tol = max(S[maxN], tol)
    end
    kpmask = S > tol
    err = 1 - sum(S[~kpmask].^2)
    # unpermute blocked U,V and get c label
    take(U, kpmask, axis=bond.leg1.axis), S[kpmask], take(V, kpmask, axis=bond.leg2.axis)
end


function eig_and_trunc(T, nev; by=identity, rev=false)
    S, U = eig(T)
    perm = sortperm(S; by=by, rev=rev)
    S = S[perm]
    U = U[:, perm]
    S = S[1:nev]
    U = U[:, 1:nev]
    return S, U
end

"""
    tm_eigs(A, dirn, nev)

Return some of the eigenvalues and vectors of the transfer matrix of A.
dirn should be "L", "R" or "BOTH", and determines which eigenvectors to return.
nev is the number of eigenpairs to return (starting with the eigenvalues with
largest magnitude).
"""
function tm_eigs_dense(A, dirn, nev)
    T = tm(A)
    D = size(T, 1)
    T = reshape(T, (D^2, D^2))
    nev = min(nev, D^2)
    
    result = ()
    if dirn == "R" || dirn == "BOTH"
        SR, UR = eig_and_trunc(T, nev; by=abs, rev=true)
        UR = [reshape(UR[:,i], (D, D)) for i in 1:nev]
        result = tuple(result..., SR, UR)
    end
    if dirn == "L" || dirn == "BOTH"
        SL, UL = eig_and_trunc(T', nev; by=abs, rev=true)
        UL = [reshape(UL[:,i], (D, D)) for i in 1:nev]
        result = tuple(result..., SL, UL)
    end
    return result
end

function tm_eigs_dense(A, dirn, nev)
    T = tm(A)
    D = size(T, 1)
    T = reshape(T, (D^2, D^2))
    nev = min(nev, D^2)
    
    result = ()
    if dirn == "R" || dirn == "BOTH"
        SR, UR = eig_and_trunc(T, nev; by=abs, rev=true)
        UR = [reshape(UR[:,i], (D, D)) for i in 1:nev]
        result = tuple(result..., SR, UR)
    end
    if dirn == "L" || dirn == "BOTH"
        SL, UL = eig_and_trunc(T', nev; by=abs, rev=true)
        UL = [reshape(UL[:,i], (D, D)) for i in 1:nev]
        result = tuple(result..., SL, UL)
    end
    return result
end

"""
    tm(A)

Return the transfer matrix of A:
 i1--A---j1
     |  
 i2--A*--j2
"""
function tm(A::MPSTensor)
    @tensor T[i1,i2,j1,j2] := A[i1,p,j1]*conj(A)[i2,p,j2]
end

"""
    tm_l(A, x)

Return y, where
/------   /------A--
|       = |      |  
\- y* -   \- x* -A*-
"""
function tm_l(x::Matrix, A::MPSTensor)
    @tensor y[i, j] := (x[a, b] * A[b, p, j]) * conj(A[a, p, i])
    return y
end

⊏ = tm_l


"""
    tm_r(A, x)

Return y, where
-- y -\   --A-- x -\
      | =   |      |
------/   --A*-----/
"""
function tm_r(A::MPSTensor, x::Matrix)
    @tensor y[i, j] := A[i, p, a] * (conj(A[j, p, b]) * x[a, b])
    return y
end

⊐ = tm_r

"""
    normalize!(A)

Normalize the UMPS defined by A, and return the dominant left and right
eigenvectors l and r of its transfer matrix, normalized so that l'*r = 1.
"""
function normalize!(A)
    SR, UR, SL, UL = tm_eigs(A, "BOTH", 1)
    S1 = SR[1]
    A ./= sqrt(S1)
    
    l = UL[1]
    r = UR[1]  
    #We need this to be 1
    n = vec(l)'*vec(r)
    abs_n = abs(n)
    phase_n = abs_n/n
    sfac = 1.0/sqrt(abs_n)
    l .*= sfac/phase_n
    r .*= sfac
    return l, r
end

"""
    tm_l_op(A, O, x)

Return y, where
/------   /------A--
|         |      |  
|       = |      O  
|         |      |  
\- y* -   \- x* -A*-
"""
function tm_l_op(A, O, x)
    @tensor y[i, j] := (x[a, b] * A[b, p2, j]) * (conj(A[a, p1, i]) * conj(O[p1, p2]))
    return y
end


"""
    tm_r_op(A, O, x)

Return y, where
-- y -\   --A-- x -\
      |     |      |
      | =   O      |
      |     |      |
------/   --A*-----/
"""
function tm_r_op(A, O, x)
    @tensor y[i, j] := (A[i, p1, a] * O[p1, p2]) * (conj(A[j, p2, b]) * x[a, b])
    return y
end


"""
    expect_local(A, O, l, r)

Return the expectation value of the one-site operator O for the UMPS state
defined by the tensor A.
"""
function expect_local(A, O, l, r)
    l = tm_l_op(A, O, l)
    expectation = vec(l)'*vec(r)
    return expectation
end

"""
    correlator_twopoint(A, O1, O2, m, l, r)

Return the (connected) two-point correlator of operators O1 and O2 for the
state UMPS(A), when O1 and O2 are i sites apart, where i ranges from 1 to m. In
other words, return <O1_0 O2_i> - <O1> <O2>, for all i = 1,...,m, where the
expectation values are with respect to the state |UMPS(A)>.
"""
function correlator_twopoint(A, O1, O2, m, l, r)
    local_O1 = expect_local(A, O1, l, r)
    local_O2 = expect_local(A, O2, l, r)
    disconnected = local_O1 * local_O2
    
    l = tm_l_op(A, O1, l)
    r = tm_r_op(A, O2, r)
    
    result = zeros(eltype(A), m)
    result[1] = vec(l)'*vec(r) - disconnected
    for i in 1:m
        r = tm_r(A, r)
        result[i] = vec(l)'*vec(r) - disconnected
    end
    return result
end

"""
    correlation_length(A)

Return the correlation length ξ of the UMPS defined by A. ξ = - 1/ln(|lambda[2]|),
where lambda[2] is the eigenvalue of the MPS transfer matrix with second largest
magnitude. (We assume here that UMPS(A) is normalized.)
"""
function correlation_length(A)
    S, U = tm_eigs(A, "L", 2)
    s2 = S[2]
    ξ = -1/log(abs(s2))
    return ξ
end

"""
    normalize!(A)

Normalize the UMPS defined by A, and return the dominant left and right
eigenvectors l and r of its transfer matrix, normalized so that they are
both Hermitian and positive semi-definite (when thought of as matrices),
and l'*r = 1.
"""
function normalize!(A)
    SR, UR, SL, UL = tm_eigs(A, "BOTH", 1)
    S1 = SR[1]
    A ./= sqrt(S1)
    
    l = UL[1]
    r = UR[1]  
    # We want both l and r to be Hermitian and pos. semi-def.
    # We know they are that, up to a phase.
    # We can find this phase, and divide it away, because it is also the
    # phase of the trace of l (respectively r).
    r_tr = trace(r)
    phase_r = r_tr/abs(r_tr)
    r ./= phase_r
    l_tr = trace(l)
    phase_l = l_tr/abs(l_tr)
    l ./= phase_l
    # Finally divide them by a real scalar that makes
    # their inner product be 1.
    n = vec(l)'*vec(r)
    abs_n = abs(n)
    phase_n = n/abs_n
    (phase_n ≉ 1) && warn("In normalize! phase_n = ", phase_n, " ≉ 1")
    sfac = sqrt(abs_n)
    l ./= sfac
    r ./= sfac
    return l, r
end

"""
    canonical_form(A, l, r)

Return a three-valent tensor Γ and a vector λ, that define the canonical
of the UMPS defined by A. l and r should be the normalized dominant
left and right eigenvectors of A.
"""
function canonical_form(A, l, r)
    l_H = 0.5*(l + l')
    r_H = 0.5*(r + r')
    (l_H ≉ l) && warn("In canonical_form, l is not Hermitian: ", vecnorm(l_H - l))
    (r_H ≉ r) && warn("In canonical_form, r is not Hermitian: ", vecnorm(r_H - r))
    evl, Ul = eig(Hermitian(l_H))
    evr, Ur = eig(Hermitian(r_H))
    X = Ur * Diagonal(sqrt.(complex.(evr)))
    YT = Diagonal(sqrt.(complex.(evl))) * Ul'
    U, λ, V = svd(YT*X)
    Xi = Diagonal(sqrt.(complex.(1./evr))) * Ur'
    YTi = Ul * Diagonal(sqrt.(complex.(1 ./ evl)))
    @tensor Γ[x,i,y] := (V'[x,a] * Xi[a,b]) * A[b,i,c] * (YTi[c,d] * U[d,y])
    return Γ, λ
end

"""
    truncate_svd(U, S, V, D)

Given an SVD of some matrix M as M = U*diagm(S)*V', truncate this
SVD, keeping only the D largest singular values.
"""
# TODO Add an optional parameter for a threshold ϵ, such that if
# the truncation error is below this, a smaller bond dimension can
# be used.
function truncate_svd(U, S, V, D)
    U = U[:, 1:D]
    S = S[1:D]
    V = V[:, 1:D]
    return U, S, V
end

"""
    double_canonicalize(ΓA, λA, ΓB, λB)

Given ΓA, λA, ΓB, λB that define an infinite MPS with two-site
translation symmetry (the Γs are the tensors and the λs are the
vectors of diagonal weights on the virtual legs), return an MPS
defined by ΓA', λA', ΓB', λB', that represents the same state,
but has been gauge transformed into the canonical form.
See Figure 4 of https://arxiv.org/pdf/0711.3960.pdf.
"""
function double_canonicalize(ΓA, λA, ΓB, λB)
    # Note that we don't quite follow Figure 4 of
    # https://arxiv.org/pdf/0711.3960.pdf: In order
    # to make maximal use of the old code we have
    # above, we build a tensor C, that includes both
    # Γ and λ of part (i) and (ii) in Figure 4.
    D, d = size(ΓA, 1, 2)
    # The next two lines are equivalent to
    # @tensor A[x,i,y] := ΓA[x,i,a] * diagm(λA)[a,y]
    # @tensor B[x,i,y] := ΓB[x,i,a] * diagm(λB)[a,y]
    A = ΓA .* reshape(λA, (1,1,D))
    B = ΓB .* reshape(λB, (1,1,D))
    @tensor C[x,i,j,y] := A[x,i,a] * B[a,j,y]
    C = reshape(C, (D, d*d, D))
    l, r = normalize!(C)
    Γ, λB = canonical_form(C, l, r)
    # The next line is equivalent to
    # @tensor Γ[x,i,y] := diagm(λB)[x,a] * Γ[a,i,b] * diagm(λB)[b,y]
    Γ .*= reshape(λB, (D,1,1)) .* reshape(λB, (1,1,D))
    Γ = reshape(Γ, (D*d, d*D))
    ΓA, λA, ΓB = svd(Γ)
    ΓA, λA, ΓB = truncate_svd(ΓA, λA, ΓB, D)  # This always causes effectively zero error!
    ΓA = reshape(ΓA, (D, d, D))
    ΓB = reshape(ΓB', (D, d, D))
    λBinv = 1. ./ λB
    # The next two lines are equivalent to
    # @tensor ΓA[x,i,y] := diagm(λBinv)[x,a] * ΓA[a,i,y]
    # @tensor ΓB[x,i,y] := ΓB[x,i,a] * diagm(λBinv)[a,y]
    ΓA .*= reshape(λBinv, (D,1,1))
    ΓB .*= reshape(λBinv, (1,1,D))
    return ΓA, λA, ΓB, λB
end
