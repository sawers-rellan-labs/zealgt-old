# Add zealgt profiles (hazel/slurm, short, normal, stub, local) and params.run_id to nextflow.config; add run_id to the schema.
import json
p = "/Users/fvrodriguez/repos/zealgt/nextflow.config"
s = open(p).read()
s = s.replace("""    // Schema validation default options
    validate_params            = true
}""", """    // Schema validation default options
    validate_params            = true

    // zealgt run options
    run_id                     = null   // names the scratch dir /share/maize/frodrig4/nf_work/<run_id> (conf/hazel.config)
}""", 1)
s = s.replace("""    test      { includeConfig 'conf/test.config'      }
    test_full { includeConfig 'conf/test_full.config' }
}""", """    test      { includeConfig 'conf/test.config'      }
    test_full { includeConfig 'conf/test_full.config' }
    // zealgt execution profiles (conf/hazel.config header): hazel,stub | hazel,short | hazel,normal | hazel,local
    hazel     { includeConfig 'conf/hazel.config'     }
    slurm     { includeConfig 'conf/hazel.config'     }
    short     { includeConfig 'conf/short.config'     }
    normal    { includeConfig 'conf/normal.config'    }
    stub      { includeConfig 'conf/stub.config'      }
    local     { includeConfig 'conf/local.config'     }
}""", 1)
open(p, "w").write(s)

sp = "/Users/fvrodriguez/repos/zealgt/nextflow_schema.json"
j = json.load(open(sp))
j["$defs"]["zealgt_run_options"] = {
    "title": "zealgt run options",
    "type": "object",
    "fa_icon": "fas fa-server",
    "description": "Options of a zealgt run on hazel.",
    "properties": {
        "run_id": {
            "type": "string",
            "description": "Run name; the run's work/ and TMPDIR go to /share/maize/frodrig4/nf_work/<run_id> (profile hazel).",
            "pattern": "^[A-Za-z0-9._-]+$",
            "fa_icon": "fas fa-tag"
        }
    }
}
# insert the reference right after input_output_options
allof = j["allOf"]
allof.insert(1, {"$ref": "#/$defs/zealgt_run_options"})
json.dump(j, open(sp, "w"), indent=4, ensure_ascii=False)
open(sp, "a").write("\n")
