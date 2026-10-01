import { runMain } from "../../index.mjs";
import { query } from "./fake-sdk.mjs";

runMain({ argv: process.argv.slice(2), query });
