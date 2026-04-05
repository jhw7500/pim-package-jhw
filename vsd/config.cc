#include "config.h"

#include <iostream>

Config::Config() {
    vsd_pipe_ = "/var/run/vsd.pipe";
    tcp_port_ = 10008;
}

#if 0

#define INDENT "  "
#define STRVAL(x) ((x) ? (char*)(x) : "")

void indent(int level)
{
    int i;
    for (i = 0; i < level; i++) {
        printf("%s", INDENT);
    }
}
#endif

int Config::ParseEvent(yaml_event_t *event) {
    switch (state_) {
    case START:
        switch (event->type) {
        case YAML_MAPPING_START_EVENT:
            //state_ = ACCEPT_SECTION;
            state_ = ACCEPT_KEY;
            break;
        case YAML_SCALAR_EVENT:
            fprintf(stderr, "Ignoring unexpected scalar: %s\n",
                    (char*)event->data.scalar.value);
            break;
        case YAML_SEQUENCE_START_EVENT:
            fprintf(stderr, "Unexpected sequence.\n");
            state_ = ERROR;
            break;
        case YAML_STREAM_END_EVENT: state_ = STOP; break;
        default:
            break;
        }
        break;
#if 0
    case ACCEPT_SECTION:
        switch (event->type) {
        case YAML_SCALAR_EVENT:
            if (strcmp((char*)event->data.scalar.value, "fruit") == 0) {
               state_ = ACCEPT_LIST;
            } else {
               fprintf(stderr, "Unexpected scalar: %s\n",
                      (char*)event->data.scalar.value);
               state_ = ERROR;
            }
            break;
        default:
            fprintf(stderr, "Unexpected event while getting scalar: %d\n", event->type);
            state_ = ERROR;
            break;
        }
        break;
    case ACCEPT_LIST:
        switch (event->type) {
        case YAML_SEQUENCE_START_EVENT: state_ = ACCEPT_VALUES; break;
        default:
            fprintf(stderr, "Unexpected event while getting sequence: %d\n", event->type);
            state_ = ERROR;
            break;
        }
        break;
    case ACCEPT_VALUES:
        switch (event->type) {
        case YAML_MAPPING_START_EVENT:
            memset(&(s->data), 0, sizeof(s->data));
            state_ = ACCEPT_KEY;
            break;
        case YAML_SEQUENCE_END_EVENT: state_ = START; break;
        case YAML_DOCUMENT_END_EVENT: state_ = START; break;
        default:
            fprintf(stderr, "Unexpected event while getting mapped values: %d\n",
                    event->type);
            state_ = ERROR;
            break;
        }
        break;
#endif
    case ACCEPT_KEY:
        switch (event->type) {
        case YAML_SCALAR_EVENT:
            key_ = (char*)event->data.scalar.value;
            state_ = ACCEPT_VALUE;
            break;
        case YAML_MAPPING_END_EVENT:
            //state_ = ACCEPT_VALUES;
            state_ = START;
            break;
        default:
            fprintf(stderr, "Unexpected event while getting key: %d\n",
                    event->type);
            state_ = ERROR;
            break;
        }
        break;
    case ACCEPT_VALUE:
        switch (event->type) {
        case YAML_SCALAR_EVENT:
            if (key_ == "VSD_PIPE") {
                vsd_pipe_ = (char*)event->data.scalar.value;
            } else if (key_ == "TCP_PORT") {
                tcp_port_ = atoi((char*)event->data.scalar.value);
            } else {
                fprintf(stderr, "Ignoring unknown key: %s\n", key_.c_str());
            }
            state_ = ACCEPT_KEY;
            break;
        default:
            fprintf(stderr, "Unexpected event while getting value: %d\n",
                    event->type);
            state_ = ERROR;
            break;
        }
        break;
    case ERROR:
    case STOP:
        break;
    }
    return (state_ == ERROR ? 0 : 1);
}

bool Config::Load(void) {
    yaml_parser_t parser;
    yaml_event_t event;
    FILE *fp = fopen("/etc/cts/vsd.yml", "rt");
    if(fp==NULL) {
        std::cout << "file not found /etc/cts/vsd.yml" << std::endl;
        return false;
    }

    state_ = START;

    yaml_parser_initialize(&parser);
    yaml_parser_set_input_file(&parser, fp);

    do {
        if (!yaml_parser_parse(&parser, &event))
            goto error;
        if(ParseEvent(&event)==0) goto error;
        yaml_event_delete(&event);
    } while (state_ != STOP);

    yaml_parser_delete(&parser);
    fclose(fp);
    return true;
error:
    fprintf(stderr, "Failed to parse: %s\n", parser.problem);
    yaml_parser_delete(&parser);
    fclose(fp);
    return false;
}