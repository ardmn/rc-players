package ee.schimke.composeai.rcplayer.wasm

/**
 * Rows as `Main.kt`'s `flattenNamedValuesFromLocation` writes them, built from the same constants
 * [namedValuesFromRows] reads, for the `?namedValues=` row tests.
 */
internal object NamedValueRowsFixture {
  /** [rows] read back, decoded as the browser's `decodeURIComponent` would. */
  fun read(rows: String) = namedValuesFromRows(rows, ::decodeUriComponent)

  /** [rows] as one `?namedValues=` array. */
  fun join(vararg rows: String) = rows.joinToString(NAMED_VALUE_ROW_SEPARATOR)

  /** One element's row, each text field escaped as `encodeURIComponent`. */
  fun row(kind: String, name: String, value: String, isNumber: Boolean = false) =
    listOf(
        encodeUriComponent(kind),
        encodeUriComponent(name),
        encodeUriComponent(value),
        if (isNumber) NAMED_VALUE_NUMBER_MARK else NAMED_VALUE_TEXT_MARK,
      )
      .joinToString(NAMED_VALUE_FIELD_SEPARATOR)
}
