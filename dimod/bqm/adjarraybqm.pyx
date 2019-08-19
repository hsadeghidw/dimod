# distutils: language = c++
# cython: language_level=3
#
# Copyright 2019 D-Wave Systems Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
# =============================================================================

from numbers import Integral

cimport cython

import numpy as np

from dimod.bqm.cppbqm cimport (num_variables,
                               num_interactions,
                               get_linear,
                               get_quadratic,
                               set_linear,
                               )


# developer note: we use a function rather than a method because we want to
# use nogil
# developer note: we probably want to make this a template function in c++
# so we can determine the return type. For now we'll match Bias
@cython.boundscheck(False)
@cython.wraparound(False)
cdef Bias energy(vector[pair[size_t, Bias]] invars,
                 vector[pair[VarIndex, Bias]] outvars,
                 SampleVar[:] sample):
    """Calculate the energy of a single sample"""
    cdef Bias energy = 0

    if invars.size() == 0:
        return energy

    cdef Bias b
    cdef size_t u, v, qi
    cdef size_t qimax = outvars.size()

    # iterate backwards because it makes finding the neighbourhoods slightly
    # nicer and the order does not matter.
    # we could possibly parallelize this step (cython knows how to use +=)
    for u in reversed(range(0, invars.size())):  # throws a comp warning
        # linear bias
        energy = energy + invars[u].second * sample[u]

        # quadratic bias
        for qi in range(invars[u].first, qimax):
            v = outvars[qi].first

            if v > u:
                # we're only interested in upper-triangular
                break

            b = outvars[qi].second
            energy = energy + b * sample[u] * sample[v]

        qimax = invars[u].first

    return energy


cdef class AdjArrayBQM:
    """

    This can be instantiated in several ways:

        AdjVectorBQM()
            Creates an empty binary quadratic model

        AdjVectorBQM(n)
            Where n is the number of nodes.

        AdjVectorBQM((linear, [quadratic, [offset]]))
            Where linear, quadratic are:
                dict[int, bias]
                sequence[bias]
            *NOT IMPLEMENTED YET*

        AdjVectorBQM(bqm)
            Where bqm is another binary quadratic model (equivalent to
            bqm.to_adjvector())
            *NOT IMPLEMENTED YET*

        AdjVectorBQM(D)
            Where D is a dense matrix D

    """

    def __cinit__(self, *args, **kwargs):
        # Developer note: if VarIndex or Bias were fused types, we would want
        # to do a type check here but since they are fixed...
        self.dtype = np.dtype(np.double)
        self.index_dtype = np.dtype(np.uintc)

        # otherwise these would be None
        self.label_to_idx = dict()
        self.idx_to_label = dict()


    def __init__(self, object arg1=0):
        
        cdef Bias [:, :] D  # in case it's dense
        cdef size_t num_variables, num_interactions, degree
        cdef VarIndex u, v
        cdef Bias b

        if isinstance(arg1, Integral):
            self.invars_.resize(arg1)
        elif isinstance(arg1, tuple):
            raise NotImplementedError  # update docstring
        elif hasattr(arg1, "to_adjvector"):
            # we might want a more generic is_bqm function or similar
            raise NotImplementedError  # update docstring
        else:
            # assume it's dense

            D = np.atleast_2d(np.asarray(arg1, dtype=self.dtype))

            num_variables = D.shape[0]

            if D.ndim != 2 or num_variables != D.shape[1]:
                raise ValueError("expected dense to be a 2 dim square array")

            self.invars_.resize(num_variables)

            # we could grow the vectors going through it one at a time, but
            # in the interest of future-proofing we will go through once,
            # resize the outvars_ then go through it again to fill

            # figure out the degree of each variable and consequently the
            # number of interactions
            num_interactions = 0  # 2x num_interactions because count degree
            for u in range(num_variables):
                degree = 0
                for v in range(num_variables):
                    if u != v and (D[v, u] or D[u, v]):
                        degree += 1

                if u < num_variables - 1:
                    self.invars_[u + 1].first = degree + self.invars_[u].first

                num_interactions += degree

            self.outvars_.resize(num_interactions)

            for u in range(num_variables):
                degree = 0
                for v in range(num_variables):
                    if u == v:
                        self.invars_[u].second = D[u, v]
                    elif D[v, u] or D[u, v]:
                        self.outvars_[self.invars_[u].first + degree].first = v
                        self.outvars_[self.invars_[u].first + degree].second = D[v, u] + D[u, v]
                        degree += 1

                    
    def __len__(self):
        return self.num_variables

    @property
    def num_variables(self):
        return num_variables(self.invars_, self.outvars_)

    @property
    def num_interactions(self):
        return num_interactions(self.invars_, self.outvars_)

    @property
    def shape(self):
        return self.num_variables, self.num_interactions

    def has_variable(self, object v):
        if v in self.label_to_idx:
            return True
        return (v in range(num_variables(self.invars_, self.outvars_)) and
                v not in self.idx_to_label)  # not overwritten

    def get_linear(self, object v):
        if v < 0 or v >= self.num_variables:
            raise ValueError
        cdef VarIndex var = v
        return get_linear(self.invars_, self.outvars_, var)

    def get_quadratic(self, object u, object v):
        # todo: return default?

        if u == v:
            raise ValueError('No interaction between {} and {}'.format(u, v))

        if not self.has_variable(u):
            raise ValueError('{} is not a variable'.format(u))
        cdef VarIndex ui = self.label_to_idx.get(u, u)

        if not self.has_variable(v):
            raise ValueError('{} is not a variable'.format(v))
        cdef VarIndex vi = self.label_to_idx.get(v, v)

        cdef pair[Bias, bool] out = get_quadratic(self.invars_, self.outvars_,
                                                  ui, vi)

        if not out.second:
            raise ValueError('No interaction between {} and {}'.format(u, v))

        return out.first

    def set_linear(self, object v, Bias b):

        if not self.has_variable(v):
            raise ValueError('{} is not a variable'.format(v))
        cdef VarIndex vi = self.label_to_idx.get(v, v)

        set_linear(self.invars_, self.outvars_, vi, b)

    def set_quadratic(self, object u, object v, Bias b):
        raise NotImplementedError

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def energies(self, SampleVar[:, :] samples):
        cdef size_t num_samples = samples.shape[0]

        if samples.shape[1] != len(self):
            raise ValueError("Mismatched variables")

        # type is hardcoded for now
        energies = np.empty(num_samples, dtype=self.dtype)  # gil
        cdef Bias[::1] energies_view = energies

        # todo: prange and nogil, we can use static schedule because the
        # calculation should be the same for each sample.
        # See https://github.com/dwavesystems/dimod/pull/379 for a discussion
        # of some of the issues around OMP_NUM_THREADS
        cdef size_t row
        for row in range(num_samples):
            energies_view[row] = energy(self.invars_,
                                        self.outvars_,
                                        samples[row, :])

        return energies

    def to_lists(self):
        """Dump to two lists, mostly for testing"""
        return list(self.invars_), list(self.outvars_)
