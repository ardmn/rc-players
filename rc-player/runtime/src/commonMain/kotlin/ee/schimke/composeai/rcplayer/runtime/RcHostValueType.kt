package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable

/**
 * The type of a named variable's value as host contracts name it (a host can supply most of them;
 * `image` exists in declarations only): the document wire type it is stored as ([RcNamedVariable]'s
 * `*_TYPE`) and every name a host contract uses for it.
 *
 * The one owner of these names in code. Each host keeps its public vocabulary (the Wasm embed's
 * `?namedValues=` kinds, rc-widget's binding names) and resolves it here, so a name means the same
 * type everywhere and existing contracts keep their spellings: `text` and `string`, `float[]` and
 * `float_array`, `dp` (a float) all resolve. A boolean is held as an integer 1 or 0, as AndroidX's
 * `setNamedBooleanOverride` stores it.
 */
public enum class RcHostValueType(public val wireType: Int, public val names: List<String>) {
  STRING(RcNamedVariable.STRING_TYPE, listOf("string", "text")),
  FLOAT(RcNamedVariable.FLOAT_TYPE, listOf("float", "dp")),
  COLOR(RcNamedVariable.COLOR_TYPE, listOf("color")),
  IMAGE(RcNamedVariable.IMAGE_TYPE, listOf("image")),
  INT(RcNamedVariable.INT_TYPE, listOf("int")),
  BOOLEAN(RcNamedVariable.INT_TYPE, listOf("bool")),
  LONG(RcNamedVariable.LONG_TYPE, listOf("long")),
  FLOAT_ARRAY(RcNamedVariable.FLOAT_ARRAY_TYPE, listOf("float[]", "float_array"));

  public companion object {
    /** The type a host calls [name], or null when no contract uses that name. */
    public fun ofName(name: String): RcHostValueType? = entries.firstOrNull { name in it.names }

    /**
     * The type a variable of [wireType] holds, or null for an unknown wire type. [INT] for
     * `INT_TYPE`: a boolean is an integer once stored, so [BOOLEAN] is never the answer here.
     */
    public fun ofWire(wireType: Int): RcHostValueType? = entries.firstOrNull {
      it.wireType == wireType
    }
  }
}

/** The host value type of this value: the one mapping from a value to its type. */
public val RcNamedValue.hostType: RcHostValueType
  get() =
    when (this) {
      is RcNamedValue.Text -> RcHostValueType.STRING
      is RcNamedValue.FloatValue -> RcHostValueType.FLOAT
      is RcNamedValue.Color -> RcHostValueType.COLOR
      is RcNamedValue.Integer -> RcHostValueType.INT
      is RcNamedValue.LongValue -> RcHostValueType.LONG
      is RcNamedValue.BooleanValue -> RcHostValueType.BOOLEAN
      is RcNamedValue.FloatArrayValue -> RcHostValueType.FLOAT_ARRAY
    }

/**
 * Whether this value can be written to a variable of [wireType]: the one compatibility rule every
 * host and the player use. A boolean fits an integer variable.
 */
public fun RcNamedValue.fitsWireType(wireType: Int?): Boolean = hostType.wireType == wireType
