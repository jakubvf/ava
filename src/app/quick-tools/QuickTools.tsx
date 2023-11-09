import { Alert, Button, Link, Page, Table } from "../_components"
import { examples } from "./_examples"

export const QuickTools = () => {
  return (
    <Page>
      <Page.Header title="Quick Tools">
        <Button href="/quick-tools/new">Create New</Button>
      </Page.Header>

      <Page.Content>
        <Alert class="mb-8">
          <strong>This feature is experimental.</strong> <br />
          No changes are saved to the database
        </Alert>

        <Table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Description</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {examples.map(t => (
              <tr>
                <td>
                  <Link href={`/quick-tools/${t.id}`}>{t.name}</Link>
                </td>
                <td>{t.description}</td>
                <td>
                  <Link href={`/quick-tools/${t.id}/edit`}>Edit</Link>
                </td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Page.Content>
    </Page>
  )
}
