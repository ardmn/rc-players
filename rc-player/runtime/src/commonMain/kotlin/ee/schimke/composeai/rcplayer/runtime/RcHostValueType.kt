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
public enum class RcHostValueType(
  public val wireType: Int,
  /** Whether a host can supply a value of this type ([IMAGE] exists in declarations only). */
  public val hostSuppliable: Boolean,
  vararg names: String,
) {
  STRING(RcNamedVariable.STRING_TYPE, true, "string", "text"),
  FLOAT(RcNamedVariable.FLOAT_TYPE, true, "float", "dp"),
  COLOR(RcNamedVariable.COLOR_TYPE, true, "color"),
  IMAGE(RcNamedVariable.IMAGE_TYPE, false, "image"),
  INT(RcNamedVariable.INT_TYPE, true, "int"),
  BOOLEAN(RcNamedVariable.INT_TYPE, true, "bool"),
  LONG(RcNamedVariable.LONG_TYPE, true, "long"),
  FLOAT_ARRAY(RcNamedVariable.FLOAT_ARRAY_TYPE, true, "float[]", "float_array");

  // Private and copied, so no caller (Java included) can change the shared vocabulary.
  private val names: List<String> = names.toList()

  /** The first name host contracts use for this type (`string`, `float[]`, ...). */
  public val canonicalName: String
    get() = names.first()

  /** Whether some host contract calls this type [name]. */
  public fun hasName(name: String): Boolean = name in names

  public companion object {
    /** The type a host calls [name], or null when no contract uses that name. */
    public fun ofName(name: String): RcHostValueType? = entries.firstOrNull { it.hasName(name) }

    /**
     * The type a variable of [wireType] holds, or null for an unknown wire type. [INT] for
     * `INT_TYPE`, never [BOOLEAN]: a boolean is an integer once stored.
     */
    public fun ofWire(wireType: Int): RcHostValueType? = entries.firstOrNull {
      it.wireType == wireType && it != BOOLEAN
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
