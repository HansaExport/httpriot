typedef enum {
    kHTTPRiotMethodGet = 1,
    kHTTPRiotMethodPost,
    kHTTPRiotMethodPut,
    kHTTPRiotMethodPush
} kHTTPRiotMethod;

typedef enum {
    kHTTPRiotJSONFormat = 1,
    kHTTPRiotXMLFormat
} kHTTPRiotFormat;

#define HTTPRiotErrorDomain @"com.labratrevenge.HTTPRiot.ErroDomain"