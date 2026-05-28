---
name: code-review-java
description: >-
  Use when reviewing Java source code for security vulnerabilities. Covers
  Spring Boot patterns, EL injection, deserialization, XXE, SQL injection,
  path traversal, SSRF, and auth bypass. Based on analysis of Discourse,
  RIPE NCC rpki-commons, and enterprise Java patterns.
---

# Java Code Review for Vulnerabilities

## Vulnerability Classes (prioritized)

### 1. Expression Language (EL) Injection
```java
// BAD: user input evaluated as EL
String expr = "${" + userInput + "}";
ExpressionParser parser = new SpelExpressionParser();
parser.parseExpression(expr).getValue();

// BAD: Spring controller with EL
@GetMapping("/eval")
public String eval(@RequestParam String expr) {
    ExpressionParser parser = new SpelExpressionParser();
    return parser.parseExpression(expr).getValue().toString();
}

// GOOD: use fixed templates, never concat user input
TemplateParserContext ctx = new TemplateParserContext();
String template = "Hello, #{#user}";  // predefined template
```

**Look for:**
- `SpelExpressionParser`, `ExpressionParser`
- `parseExpression()` with user-controlled strings
- `@Value` annotations with `${...}` from user input
- JSP EL: `${param.userInput}` in templates
- Spring Boot actuator with expression evaluation enabled

### 2. Deserialization Vulnerabilities
```java
// BAD: unsafe deserialization
ObjectInputStream ois = new ObjectInputStream(is);
Object obj = ois.readObject();  // arbitrary class instantiation

// BAD: unsafe Jackson polymorphic deser
ObjectMapper mapper = new ObjectMapper();
mapper.enableDefaultTyping();  // enables arbitrary types

// BAD: unsafe YAML deser
Yaml yaml = new Yaml();
Object obj = yaml.load(userInput);

// GOOD: validate class before deserialization
ois.readObject();  // but wrap in try-catch with class whitelist
```

**Checklist:**
- `ObjectInputStream.readObject()` without filtering
- `Jackson` with `enableDefaultTyping()` or `@JsonTypeInfo` without `@JsonSubTypes`
- `XStream.fromXML()` (legacy, very dangerous)
- `SnakeYAML` / `Yaml.load()` — can instantiate any class
- `XMLDecoder` (Java beans XML) — remote code execution
- `JNDI` lookups with user input (`InitialContext.lookup()`)

### 3. SQL Injection
```java
// BAD: string concatenation
String query = "SELECT * FROM users WHERE id = " + userId;
Statement stmt = connection.createStatement();
ResultSet rs = stmt.executeQuery(query);

// BAD: MyBatis with ${} (not #{})
@Select("SELECT * FROM users WHERE name LIKE '%${name}%'")

// GOOD: parameterized query
String query = "SELECT * FROM users WHERE id = ?";
PreparedStatement pstmt = connection.prepareStatement(query);
pstmt.setInt(1, userId);

// GOOD: JPA with named params
@Query("SELECT u FROM User u WHERE u.email = :email")
User findByEmail(@Param("email") String email);
```

**Look for:**
- `Statement` instead of `PreparedStatement`
- String concatenation in JPA `@Query` with `+` operator
- JPA Criteria API with unsafe string building
- Hibernate HQL with concatenation
- MyBatis `${}` (substitution) vs `#{}` (binding)
- Spring Data JPA `@Query` with `?#{[0]}` SpEL

### 4. XXE (XML External Entity)
```java
// BAD: default DocumentBuilder (XXE vulnerable)
DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
DocumentBuilder builder = factory.newDocumentBuilder();
Document doc = builder.parse(inputStream);  // XXE!

// GOOD: disable external entities
DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);

// GOOD: SAX parser with security
SAXParserFactory spf = SAXParserFactory.newInstance();
spf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
```

**Check all XML parsers:**
- `DocumentBuilderFactory`, `SAXParserFactory`
- `SAXBuilder` (JDom), `XMLInputFactory` (StAX)
- `javax.xml.transform.TransformerFactory` (XSLT)
- `Unmarshaller` (JAXB) — also vulnerable by default
- `XPathExpression.evaluate()` — can trigger XXE

### 5. Path Traversal
```java
// BAD: direct user input
String path = "/uploads/" + userInput;
File file = new File(path);
byte[] content = Files.readAllBytes(file.toPath());

// BAD: using getName() instead of getCanonicalPath()
File file = new File(BASE_DIR, userInput);
if (file.getPath().startsWith(BASE_DIR)) {  // can be bypassed with "../"
    // ...
}

// GOOD: canonical path check
File file = new File(BASE_DIR, userInput);
String canonicalPath = file.getCanonicalPath();
if (!canonicalPath.startsWith(new File(BASE_DIR).getCanonicalPath())) {
    throw new SecurityException("Path traversal detected");
}

// GOOD: Spring Resource
@GetMapping("/files/{filename}")
public Resource getFile(@PathVariable String filename) {
    Path file = Path.of(UPLOAD_DIR).resolve(filename).normalize();
    if (!file.startsWith(UPLOAD_DIR)) throw new SecurityException();
    return new UrlResource(file.toUri());
}
```

### 6. SSRF (Server-Side Request Forgery)
```java
// BAD: vanilla URL connection
URL url = new URL(userInput);
HttpURLConnection conn = (HttpURLConnection) url.openConnection();

// BAD: RestTemplate without validation
RestTemplate rest = new RestTemplate();
String result = rest.getForObject(userInput, String.class);

// BAD: WebClient without filter
WebClient client = WebClient.create();
String result = client.get().uri(userInput).retrieve().bodyToMono(String.class);

// BETTER: with host allowlist
URI uri = new URI(userInput);
if (!ALLOWED_HOSTS.contains(uri.getHost())) {
    throw new SecurityException();
}

// GOOD: RestTemplate with custom interceptors
RestTemplate rest = new RestTemplate();
rest.setRequestFactory(new HttpComponentsClientHttpRequestFactory() {{
    setConnectTimeout(5000);
    // set a custom HttpClient with redirect disabled
    setHttpClient(HttpClientBuilder.create()
        .disableRedirectHandling()
        .setProxySelector(new DenyInternalProxySelector())
        .build());
}});
```

### 7. Spring Security Misconfiguration
```java
// BAD: permitAll on sensitive endpoints
http.authorizeHttpRequests()
    .requestMatchers("/api/admin/**").permitAll()  // oops!

// BAD: disabled CSRF
http.csrf().disable();  // check if this is REALLY needed

// BAD: too permissive CORS
@CrossOrigin(origins = "*")  // any origin can call
@CrossOrigin(origins = "${cors.origins}")  // check config default

// BAD: method security annotation missing
@PostMapping("/admin/users")
// @PreAuthorize("hasRole('ADMIN')")  // MISSING!
public User createUser(@RequestBody User user) { ... }

// GOOD: explicit role checks
@PreAuthorize("hasRole('ADMIN')")
@PostMapping("/admin/users")
public User createUser(@RequestBody User user) { ... }
```

### 8. Logging / Debug Leakage
```java
// BAD: logging sensitive data
log.info("Login request: {}", request.toString());  // might contain password
log.debug("User token: {}", authToken);
log.error("Failed request", new Exception("Details: " + userInput));

// BAD: stack traces in error responses
@ExceptionHandler(Exception.class)
public ResponseEntity<?> handleError(Exception e) {
    return ResponseEntity.badRequest().body(e.getMessage());  // exposes internals
}
```

## Spring Boot Specific Checks

### Actuator Exposure
```properties
# BAD: full exposure
management.endpoints.web.exposure.include=*

# BETTER: limited exposure
management.endpoints.web.exposure.include=health,info
# /actuator/env, /actuator/configprops, /actuator/beans should NOT be exposed
```

### H2 Console (dev only)
- Route: `/h2-console`
- Often left enabled in production
- Can execute arbitrary SQL
- Check: is it behind authentication?

### Swagger/OpenAPI Exposure
- Routes: `/swagger-ui.html`, `/v3/api-docs`, `/v2/api-docs`
- Should NOT be exposed in production (reveals full API surface)

## Testing Commands

```bash
# Compile-time checks
mvn dependency-check:check  # OWASP dependency check
mvn findbugs:findbugs       # FindBugs/SpotBugs
mvn pmd:pmd                 # PMD static analysis

# Runtime checks
mvn test                    # unit + integration tests

# Check for known CVEs in dependencies
mvn versions:display-dependency-updates

# Spring Boot specific
curl -s https://target.com/actuator/health
curl -s https://target.com/actuator/env
curl -s https://target.com/h2-console
curl -s https://target.com/swagger-ui.html
```

## Key Libraries to Watch

| Library | Risk | Pattern |
|---------|------|---------|
| Spring Boot | High | Actuator exposure, SpEL, auth config |
| Jackson | High | Polymorphic deser, default typing |
| SnakeYAML | Critical | `load()` = RCE via constructor |
| XStream | Critical | `fromXML()` = RCE |
| Log4j | High | JNDI lookup (CVE-2021-44228 patched) |
| Thymeleaf | Medium | Template injection with `fragments` |
| MyBatis | Medium | `${}` vs `#{}` confusion |
| JAXB | Medium | XXE via default unmarshalling |

## References
- Discourse Backup Path Traversal: Java/ Rails pattern applies (sesión 40-41)
- RIPE NCC rpki-commons: Spring Boot, bien asegurado (sesión 44)
- Spring Security docs: https://docs.spring.io/spring-security/reference/
