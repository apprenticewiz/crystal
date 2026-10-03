require "../abi"

# Based on clang's LoongArch ABI lowering for LP64D:
# https://github.com/llvm/llvm-project/blob/llvmorg-20.1.8/clang/lib/CodeGen/Targets/LoongArch.cpp
class Crystal::ABI::LoongArch64 < Crystal::ABI
  # Width of the general purpose and floating point registers, in bytes.
  GRLEN = 8
  FRLEN = 8

  # Number of argument registers of each kind.
  NUM_GARS = 8
  NUM_FARS = 8

  def abi_info(atys : Array(LLVM::Type), rty : LLVM::Type, ret_def : Bool, context : LLVM::Context) : Crystal::ABI::FunctionType
    abi_info(atys, rty, ret_def, context, Array(Bool?).new(atys.size, nil))
  end

  def abi_info(atys : Array(LLVM::Type), rty : LLVM::Type, ret_def : Bool, context : LLVM::Context, signedness : Array(Bool?)) : Crystal::ABI::FunctionType
    ret_ty = compute_return_type(rty, ret_def, context)

    gars = ret_ty.kind.indirect? ? NUM_GARS - 1 : NUM_GARS
    fars = NUM_FARS
    arg_tys = atys.map_with_index do |aty, i|
      arg_ty, gars, fars = classify(aty, context, signedness[i]?, gars, fars)
      arg_ty
    end

    FunctionType.new(arg_tys, ret_ty)
  end

  def align(type : LLVM::Type) : Int32
    align(type, 8)
  end

  def size(type : LLVM::Type) : Int32
    size(type, 8)
  end

  private def compute_return_type(rty, ret_def, context)
    return ArgType.direct(context.void) unless ret_def

    # Return values follow the argument rules, with two registers of each kind.
    ret_ty, _, _ = classify(rty, context, nil, 2, 2)
    ret_ty.kind.indirect? ? ArgType.indirect(rty, LLVM::Attribute::StructRet) : ret_ty
  end

  # Classifies a value given the argument registers still available, and
  # returns its ABI type along with the registers left afterwards.
  private def classify(type, context, signed, gars, fars) : {ArgType, Int32, Int32}
    case type.kind
    when .float?, .double?
      return {ArgType.direct(type), gars, fars - 1} if fars > 0
      return {ArgType.direct(type), {gars - 1, 0}.max, fars}
    when .integer?, .pointer?
      needed = size(type) > GRLEN ? 2 : 1
      return {non_struct(type, signed), {gars - needed, 0}.max, fars}
    end

    type_size = size(type)

    # Zero-sized aggregates (empty structs) are not passed at all.
    return {ArgType.ignore(type), gars, fars} if type_size == 0

    # A struct made of one float, two floats, or a float and an integer is
    # passed in floating point registers (plus one general purpose register),
    # as long as enough of them are left.
    if fields = fp_fields(type)
      needed_fars = fields.count { |field| float?(field) }
      needed_gars = fields.size - needed_fars
      if needed_fars <= fars && needed_gars <= gars
        cast = fields.size == 1 ? fields.first : context.struct(fields)
        return {ArgType.direct(type, cast), gars - needed_gars, fars - needed_fars}
      end
    end

    # Other aggregates of up to two registers are coerced to integers, larger
    # ones are passed by reference.
    if type_size <= GRLEN
      {ArgType.direct(type, context.int64), {gars - 1, 0}.max, fars}
    elsif type_size <= 2 * GRLEN
      cast = align(type) == 2 * GRLEN ? context.int128 : context.int64.array(2)
      {ArgType.direct(type, cast), {gars - 2, 0}.max, fars}
    else
      {ArgType.indirect(type, nil), {gars - 1, 0}.max, fars}
    end
  end

  # Returns the flattened fields of `type` when they qualify for the floating
  # point calling convention: one float, two floats, or a float and an integer
  # of at most GRLEN bytes.
  private def fp_fields(type) : Array(LLVM::Type)?
    fields = [] of {LLVM::Type, Int32}
    return unless flatten_fp_fields(type, 0, fields)

    case fields.size
    when 1
      first, offset = fields[0]
      [first] if float?(first) && offset == 0
    when 2
      first, first_offset = fields[0]
      second, second_offset = fields[1]
      return unless float?(first) || float?(second)

      # The coerced value is built by copying the struct's bytes into the
      # cast type, so the fields must sit where the cast type puts them.
      if first_offset == 0 && second_offset == align_offset(size(first), second)
        [first, second]
      end
    end
  end

  private def flatten_fp_fields(type, offset, fields) : Bool
    case type.kind
    when .float?, .double?
      return false if fields.size == 2
      fields << {type, offset}
    when .integer?
      return false if fields.size == 2 || size(type) > GRLEN
      # two integers do not qualify
      return false if fields.any? { |(field, _)| field.kind.integer? }
      fields << {type, offset}
    when .array?
      element = type.element_type
      element_size = size(element)
      type.array_size.times do |i|
        return false unless flatten_fp_fields(element, offset + i * element_size, fields)
      end
    when .struct?
      return false if type.packed_struct?
      field_offset = 0
      type.struct_element_types.each do |element|
        field_offset = align_offset(field_offset, element)
        return false unless flatten_fp_fields(element, offset + field_offset, fields)
        field_offset += size(element)
      end
    else
      # pointers never qualify
      return false
    end
    true
  end

  private def float?(type)
    type.kind.float? || type.kind.double?
  end

  private def non_struct(type, signed)
    ArgType.direct(type, attr: extension(type, signed))
  end

  # Integers narrower than GRLEN are extended by the caller: 32-bit ones are
  # always sign extended, narrower ones according to their signedness.
  private def extension(type, signed)
    return unless type.kind.integer?

    case type.int_width
    when 1     then LLVM::Attribute::ZExt
    when 8, 16 then signed == false ? LLVM::Attribute::ZExt : LLVM::Attribute::SExt
    when 32    then LLVM::Attribute::SExt
    end
  end
end
