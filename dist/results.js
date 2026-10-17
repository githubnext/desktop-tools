/** The JSON object a native read returned as its text. */
export function parseResult(result) {
    return JSON.parse(result.text);
}
/** An error's message, bounded so a result never carries a runaway native error. */
export function errorMessage(error) {
    return (error instanceof Error ? error.message : String(error)).slice(0, 2000);
}
