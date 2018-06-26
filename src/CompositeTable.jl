#=
This code provides the framework to stich together two separate tables
(either concatenating them horizontally or vertically).
=#

import Base: join, getindex, size, hcat, vcat

mutable struct IndexedTable{N, M}
    columns::Vector
    row_index::Index{N}
    col_index::Index{M}
end

IndexedTable(t::TableCol) = begin
    columns     = vcat(t)
    row_index   = keys(t.data) |> collect
    col_index   = vcat(t.header)
    return IndexedTable(columns, row_index, col_index)
end

########################################################################
#################### Merging and Concatenating #########################
########################################################################

function vcat(t1::IndexedTable{N, M}, t2::IndexedTable{N,M}) where {N,M}

    # Row Indices stay the same except within the highest group, where
    # they need to be shifted up in order to keep the index unique
    shift       =   maximum(get_idx(t1.row_index, 1)) -
                    minimum(get_idx(t2.row_index, 1)) + 1
    new_index   = map(t2.row_index) do idx
        i1 = idx.idx[1] + shift
        new_idx = tuple(i1, idx.idx[2:end]...)
        return update_index(idx, new_idx)
    end

    new_columns = deepcopy(t2.columns)
    for col in new_columns
        for (idx, new_idx) in zip(t2.row_index, new_index)
            col[new_idx] = pop!(col.data, idx)
        end
    end

    row_index = vcat(t1.row_index, new_index)

    # Columns
    col_index = deepcopy(t1.col_index)
    columns   = deepcopy(t1.columns)
    for (i, idx) in enumerate(t2.col_index)

        # Figure out where to insert the column
        new_idx, s = insert_index!(col_index, idx)

        # It might be a new column
        if s > length(columns)
            push!(columns, new_columns[i])
        # If not, we need to move all the data over
        else
            for (key, value) in new_columns[i].data
                columns[s].data[key] = value
            end
        end
    end


    return IndexedTable(columns, row_index, col_index)

end

function hcat(t1::IndexedTable{N, M}, t2::IndexedTable{N,M}) where {N,M}

    # Don't pass changes up the stack
    # t1 = deepcopy(t1)
    # t2 = deepcopy(t2)

    # Column Indices stay the same except within the highest group,
    # where they need to be shifted up in order to keep the index unique
    shift       =   maximum(get_idx(t1.col_index, 1)) -
                    minimum(get_idx(t2.col_index, 1)) + 1
    new_index   = map(t2.col_index) do idx
        i1 = idx.idx[1] + shift
        return update_index(idx, tuple(i1, idx.idx[2:end]...))
    end
    col_index   = vcat(t1.col_index, new_index)


    # Row indices are merged in (inserted) one at a time, maintaining
    # strict insertion order in all index levels but the lowest one
    new_columns = deepcopy(t2.columns)
    row_index   = t1.row_index
    for idx in t2.row_index

        # Insert the index and recover the new_index and the required
        # insertion point
        new_idx, s = insert_index!(row_index, idx)

        # Rename the old indexes to the new ones
        for col in new_columns
            val          = pop!(col.data, idx)
            col[new_idx] = val
        end
    end

    # Remap the internal column headers to keep them consistent
    old_new     = Dict(Pair.(t2.col_index, new_index))
    for col in new_columns
        col.header = old_new[col.header]
    end

    # Now, we're ready to append the columns together.
    columns     = vcat(t1.columns, new_columns)

    return IndexedTable(columns, row_index, col_index)
end

hcat(tables::Vararg{IndexedTable{N,M}, K}) where {N,M,K}= reduce(hcat, tables)
vcat(tables::Vararg{IndexedTable{N,M}, K}) where {N,M,K}= reduce(vcat, tables)



########################################################################
#################### General Indexing ##################################
########################################################################

function insert_index!(index::Index{N}, idx::TableIndex{N}) where N

    range = searchsorted(index, idx, lt=isless_group)

    # If it's empty, insert it in the right position
    if isempty(range)
        insert!(index, range.start, idx)
        return idx, range.start

    # Otherwise, check to see whether or not the last level matches
    # already
    else

        N_index = get_idx(index[range], N)
        N_names = get_name(index[range], N)

        # If it does, then we don't have to do anything except check
        # that the strings are right
        if idx.name[N] in N_names
            loc = find(N_names .== idx.name[N])[1]

            # if ! (N_names[loc] == idx.name)
            #     throw(error(replace("""
            #     The index is screwed up.  Have you been messing around
            #     with the internals?  Don't do that.  Things need to be
            #     sorted properly for this to work.
            #     """, "\n", " ")))
            # end

            # Here's the new index
            new_idx = update_index(idx, tuple(idx.idx[1:N-1]..., loc))
            return new_idx, range.start + loc - 1
        else
            # Otherwise, it's not there so we need to insert it into the
            # index, and its last integer level should be one higher
            # than all the others
            new_idx = update_index(idx, tuple(idx.idx[1:N-1]...,
                                              maximum(N_index)+1))

            insert!(index, range.stop+1, new_idx)
            return new_idx, range.stop + 1
        end
    end
end

get_idx(index)               = map(x->x.idx, index)
get_idx(index, level::Int)   = map(x->x.idx[level], index)
get_name(index)              = map(x->x.name, index)
get_name(index, level::Int)  = map(x->x.name[level], index)

function find_level(index::Index{N}, idx::Idx{N}, level::Int) where N
    range = searchsorted(get_level(index, level), idx[level])
    return range
end

function add_level(index::Vector{TableIndex{N}}, level,
                   name::Printable="") where N
    return map(index) do idx
        return TableIndex(tuple(level, idx.idx...),
                          tuple(Symbol(name), idx.name...))
    end
end

"""
```
add_row_level(t::IndexedTable, level::Int, name::$Printable="")
```
Add's a new level to the row index with the given `level` for the
integer component of the index, and `name` for the symbol component
"""
function add_row_level(t::IndexedTable{N,M},
                       level::Int, name::Printable="") where {N,M}

    new_rows = add_level(t.row_index, level, name)

    old_new  = Dict(Pair.(t.row_index, new_rows)...)

    new_columns = []
    for col in t.columns
        data = TableDict{N+1, FormattedNumber}()
        for (key, value) in col.data
            data[old_new[key]] = value
        end
        push!(new_colums, TableCol(col.header, data))
    end

    return IndexedTable(new_columns, new_rows, t.col_index)
end

"""
```
add_col_level(t::IndexedTable, level::Int, name::$Printable="")
```
Add's a new level to the column index with the given `level` for the
integer component of the index, and `name` for the symbol component
"""
function add_col_level(t::IndexedTable{N,M},
                       level::Int, name::Printable="") where {N,M}

    new_cols = add_level(t.col_index, level, name)
    old_new  = Dict(Pair.(t.col_index, new_cols))

    new_columns = []
    for col in t.columns
        push!(new_columns, TableCol(old_new[col.header],
                                    col.data))
    end

    return IndexedTable(new_columns, t.row_index, new_cols)
end

########################################################################
#################### Access Methods ####################################
########################################################################

Indexable{N}  = Union{TableIndex{N}, Name{N}, Idx{N}}
Idexable1D    = Union{Printable, Integer}

function row_loc(t::IndexedTable{N,M}, idx::Indexable{N}) where {N,M}
    locate(t.row_index, idx)
end

function col_loc(t::IndexedTable{N,M}, idx::Indexable{N}) where {N,M}
    locate(t.col_index, idx)
end

function loc(t::IndexedTable{N,M},
             ridx::Indexable{N},
             cidx::Indexable{M}) where {N,M}

    rloc = locate(t.row_index, ridx)
    cloc = locate(t.col_index, cidx)

    if isempty(rloc) | isempty(cloc)
        throw(KeyError("key ($row, $col) not found"))
    elseif length(rloc) > 1
        throw(KeyError("""
           $row does not uniquely identify a row
           """))
    elseif length(cloc) > 1
        throw(KeyError("""
            $col does not uniquely identify a column
            """))
    else
        return rloc[1], cloc[1]
    end
end

function locate(index::Vector{TableIndex{N}},idx::TableIndex{N}) where N
    return findin(idx, index)
end

function locate(index::Vector{TableIndex{N}}, idx::Name{N}) where N
    return find(x->x.name == idx, index)
end

function locate(index::Vector{TableIndex{N}}, idx::Idx{N}) where N
    return find(x->x.idx == idx, index)
end

function getindex(t::IndexedTable{N,M}, row::Indexable{N},
                  col::Indexable{M}) where {N,M}
    rloc, cloc = loc(t, row, col)
    return t.columns[cloc][t.row_index[rloc]]
end

function setindex!(t::IndexedTable, args...)
    throw(error("setindex! not implemented yet"))
end

# Fallback Methods
function getindex(t::IndexedTable, row, col)
    return t[tuple(row), tuple(col)]
end

function getindex(t::IndexedTable, row::Indexable, col)
    return t[row, tuple(col)]
end

function getindex(t::IndexedTable, row, col::Indexable)
    return t[tuple(row), col]
end
